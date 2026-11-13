"""One guest boot through the real rewrite path, watched: the daemon's own
rewrite code in the guest, the adapter, the host relay and the sandboxed
worker, with the copy-only tap (worker_tap.py) between the host and the
worker. While the boot runs, a sampler reads every second the memory and CPU
of every worker process alive (a new one follows each loss), the guest's
virtual machine, the host and the host's tor, and the system's swap, memory
pressure and GPU use; the worker's own log lines (token counts, timings and
MLX's memory, never content) are streamed from the unified log. The guest's
console and the host's own log, tor's lines included, are timed line by line
as they arrive.

Times are nanoseconds on CLOCK_MONOTONIC_RAW, shared with the tap and the
log; it keeps counting while the Mac sleeps.
"""

import ctypes
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from fetch_model import DEST

ROOT = Path(__file__).resolve().parent.parent
HOST = ROOT / "host/.build/release/cloak-host"
# The Tor Project's tor, which the host runs for the guest (host/build.sh),
# and its lasting folder, which keeps its state from one boot to the next.
TOR = ROOT / "host/.build/tor/tor"
TOR_DATA = DEST.parent / "tor"
KERNEL = ROOT / "guest/build/Image"
INITRD = ROOT / "guest/build/initrd.gz"
TAP = Path(__file__).resolve().parent / "worker_tap.py"
VM_PROCESS = "com.apple.Virtualization.VirtualMachine"
LOG_SUBSYSTEM = "sh.regents.cloak"
SAMPLE_EVERY_S = 1.0

_libc = ctypes.CDLL(None, use_errno=True)


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_timebase = _Timebase()
_libc.mach_timebase_info(ctypes.byref(_timebase))


def clock() -> int:
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)


def mach_to_ns(ticks: int) -> int:
    return ticks * _timebase.numer // _timebase.denom


class _Rusage(ctypes.Structure):
    """rusage_info_v4 from <sys/resource.h>."""

    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size",
        "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime",
        "child_user_time", "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups",
        "child_pageins", "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten",
        "cpu_time_qos_default", "cpu_time_qos_maintenance", "cpu_time_qos_background",
        "cpu_time_qos_utility", "cpu_time_qos_legacy", "cpu_time_qos_user_initiated",
        "cpu_time_qos_user_interactive", "billed_system_time", "serviced_system_time",
        "logical_writes", "lifetime_max_phys_footprint", "instructions", "cycles", "billed_energy",
        "serviced_energy", "interval_max_phys_footprint", "runnable_time")]


def process_reading(pid: int) -> list[int] | None:
    """[memory footprint, lifetime peak footprint, CPU nanoseconds], or None
    once the process is gone. The footprint is what Activity Monitor and top
    show as a process's memory."""
    usage = _Rusage()
    if _libc.proc_pid_rusage(pid, 4, ctypes.byref(usage)) != 0:
        return None
    return [usage.phys_footprint, usage.lifetime_max_phys_footprint,
            mach_to_ns(usage.user_time + usage.system_time)]


_libc.responsibility_get_pid_responsible_for_pid.restype = ctypes.c_int


def vm_processes() -> set[int]:
    found = subprocess.run(["pgrep", "-f", VM_PROCESS], capture_output=True, text=True).stdout.split()
    return {int(p) for p in found}


def vm_process_of(host_pid: int, before: set[int]) -> int | None:
    """The virtual machine process macOS starts for this host. launchd is its
    parent; macOS holds the same process responsible for it as for the host
    (the app that started the host), and it is new since the host started."""
    owner = _libc.responsibility_get_pid_responsible_for_pid(host_pid)
    return next((p for p in vm_processes() - before
                 if _libc.responsibility_get_pid_responsible_for_pid(p) == owner), None)


class _SwapUsage(ctypes.Structure):
    _fields_ = [("total", ctypes.c_uint64), ("avail", ctypes.c_uint64), ("used", ctypes.c_uint64),
                ("pagesize", ctypes.c_uint32), ("encrypted", ctypes.c_bool)]


def sysctl_int(name: str) -> int:
    value, size = ctypes.c_int(), ctypes.c_size_t(ctypes.sizeof(ctypes.c_int))
    if _libc.sysctlbyname(name.encode(), ctypes.byref(value), ctypes.byref(size), None, 0) != 0:
        raise OSError(ctypes.get_errno(), name)
    return value.value


def swap_used() -> int:
    value, size = _SwapUsage(), ctypes.c_size_t(ctypes.sizeof(_SwapUsage))
    if _libc.sysctlbyname(b"vm.swapusage", ctypes.byref(value), ctypes.byref(size), None, 0) != 0:
        raise OSError(ctypes.get_errno(), "vm.swapusage")
    return value.used


def gpu_reading() -> tuple[int | None, int | None]:
    """The GPU's device utilisation (%) and its in-use memory, system-wide:
    macOS gives per-process GPU figures only to root."""
    out = subprocess.run(["ioreg", "-r", "-d", "1", "-w", "0", "-c", "AGXAccelerator"],
                         capture_output=True, text=True).stdout
    utilisation = re.search(r'"Device Utilization %"=(\d+)', out)
    memory = re.search(r'"In use system memory"=(\d+)', out)
    return (int(utilisation[1]) if utilisation else None, int(memory[1]) if memory else None)


def vm_stat() -> dict[str, int]:
    """Page and swap counters since the Mac started."""
    out = subprocess.run(["vm_stat"], capture_output=True, text=True, check=True).stdout
    return {key.strip().lower().replace(" ", "_").replace('"', ""): int(value.strip().rstrip("."))
            for key, value in re.findall(r"^([^:\n]+):\s+(\d+)\.?$", out, re.M)}


def system_snapshot() -> dict:
    return {"swap_used_bytes": swap_used(),
            "pressure_level": sysctl_int("kern.memorystatus_vm_pressure_level"),
            "free_percent": sysctl_int("kern.memorystatus_level"),
            "load_average": list(os.getloadavg()),
            "vm_stat": vm_stat()}


@dataclass
class Boot:
    name: str
    started_ns: int
    ended_ns: int
    host_status: int | None
    over_time: bool
    console: list[tuple[int, str]]
    host_stderr: list[tuple[int, str]]
    results: dict[str, dict]
    events: list[dict]
    worker_log: list[dict]
    samples: list[dict]
    vm_pid: int | None
    system_start: dict
    system_end: dict


def _launcher(directory: Path, events: Path, worker: Path) -> Path:
    """The program the host starts as its worker: the tap, which starts the
    real worker with the host's arguments."""
    launcher = directory / "tapped-worker"
    launcher.write_text(f'#!/bin/sh\nexec "{sys.executable}" -I "{TAP}" "{events}" "{worker}" "$@"\n')
    launcher.chmod(0o755)
    return launcher


class _LogStream:
    """The worker's own log lines from the unified log, while the boot runs."""

    def __init__(self):
        self.lines: list[dict] = []
        self.process = subprocess.Popen(
            ["/usr/bin/log", "stream", "--level", "info", "--style", "ndjson",
             "--predicate", f'subsystem == "{LOG_SUBSYSTEM}"'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        # The first line says the stream is filtering; it is listening from then on.
        self.process.stdout.readline()
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self):
        for line in self.process.stdout:
            if line.startswith("{"):
                event = json.loads(line)
                self.lines.append({"t": mach_to_ns(event["machTimestamp"]),
                                   "message": event["eventMessage"]})

    def stop(self) -> list[dict]:
        # Lines are delivered a moment after they are written.
        time.sleep(2)
        self.process.terminate()
        self.process.wait()
        self.thread.join()
        return self.lines


def tor_process_of(host_pid: int) -> int | None:
    """The tor the host runs as its child."""
    found = subprocess.run(["pgrep", "-P", str(host_pid), "-x", "tor"], capture_output=True, text=True).stdout.split()
    return int(found[0]) if found else None


class _Sampler:
    def __init__(self, host_pid: int, events: Path, vms_before: set[int]):
        self.host_pid, self.events, self.vms_before = host_pid, events, vms_before
        self.samples: list[dict] = []
        # Every worker the host has started, from the tap's spawn events, read
        # as the events file grows; a worker found gone is never read again,
        # so a reused pid is not mistaken for it.
        self.worker_pids: list[int] = []
        self.workers_gone: set[int] = set()
        self.events_read = 0
        self.vm_pid: int | None = None
        self.tor_pid: int | None = None
        self.done = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _read_spawns(self) -> None:
        if not self.events.exists():
            return
        with self.events.open("rb") as f:
            f.seek(self.events_read)
            for line in f:
                if not line.endswith(b"\n"):
                    break  # still being written; read it next time
                self.events_read += len(line)
                if b'"spawn"' in line and (e := json.loads(line))["kind"] == "spawn":
                    self.worker_pids.append(e["pid"])

    def _workers(self) -> dict[str, list[int]]:
        """A reading of every worker alive: a lost worker may still be
        exiting while its replacement loads."""
        self._read_spawns()
        readings = {}
        for pid in self.worker_pids:
            if pid in self.workers_gone:
                continue
            if reading := process_reading(pid):
                readings[str(pid)] = reading
            else:
                self.workers_gone.add(pid)
        return readings

    def sample(self) -> dict:
        if self.vm_pid is None:
            self.vm_pid = vm_process_of(self.host_pid, self.vms_before)
        if self.tor_pid is None:
            self.tor_pid = tor_process_of(self.host_pid)
        gpu_percent, gpu_memory = gpu_reading()
        return {
            "t": clock(),
            "workers": self._workers(),
            "vm": self.vm_pid and process_reading(self.vm_pid),
            "host": process_reading(self.host_pid),
            "tor": self.tor_pid and process_reading(self.tor_pid),
            "swap_used": swap_used(),
            "pressure": sysctl_int("kern.memorystatus_vm_pressure_level"),
            "free_percent": sysctl_int("kern.memorystatus_level"),
            "gpu_percent": gpu_percent,
            "gpu_memory": gpu_memory,
        }

    def _run(self):
        while not self.done.is_set():
            self.samples.append(self.sample())
            self.done.wait(SAMPLE_EVERY_S)

    def stop(self) -> list[dict]:
        self.done.set()
        self.thread.join()
        return self.samples


def run(name: str, cases: list[dict], worker: Path, model: str, model_dir: Path,
        time_limit_s: float, during=None) -> Boot:
    """Boots the guest once and runs the cases in order through the daemon's
    rewrite code. `during(events_path, host)` runs alongside, for a check that
    acts on the worker mid-boot. A boot over `time_limit_s` is stopped and
    recorded as such; nothing is retried."""
    with tempfile.TemporaryDirectory(prefix="cloak-stage3-") as scratch:
        scratch = Path(scratch)
        events = scratch / "events.jsonl"
        cases_file = scratch / "cases.jsonl"
        cases_file.write_text("".join(json.dumps(c) + "\n" for c in cases))
        system_start = system_snapshot()
        log = _LogStream()
        vms_before = vm_processes()
        started = clock()
        host = subprocess.Popen(
            [HOST, "--kernel", KERNEL, "--initrd", INITRD, "--cases", cases_file,
             "--worker", _launcher(scratch, events, worker), "--name", model, "--dir", model_dir, "--tor", TOR,
             "--tor-data", TOR_DATA],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            sampler = _Sampler(host.pid, events, vms_before)
            console: list[tuple[int, str]] = []
            stderr: list[tuple[int, str]] = []

            def read_console():
                for line in host.stdout:
                    console.append((clock(), line.rstrip("\n")))
                    print(f"  [{name}] {line.rstrip()[:160]}", flush=True)

            def read_stderr():
                for line in host.stderr:
                    stderr.append((clock(), line))

            readers = [threading.Thread(target=read_console), threading.Thread(target=read_stderr)]
            for reader in readers:
                reader.start()
            if during:
                during(events, host)
            over_time = False
            try:
                host.wait(timeout=time_limit_s)
            except subprocess.TimeoutExpired:
                over_time = True
                host.send_signal(signal.SIGTERM)
                host.wait()
            ended = clock()
            for reader in readers:
                reader.join()
            samples = sampler.stop()
            worker_log = log.stop()
            results = {}
            for _, line in console:
                if line.startswith("{"):
                    result = json.loads(line)
                    results[result["name"]] = result
            return Boot(
                name=name, started_ns=started, ended_ns=ended, host_status=host.returncode,
                over_time=over_time, console=console, host_stderr=stderr, results=results,
                events=[json.loads(line) for line in events.read_text().splitlines()] if events.exists() else [],
                worker_log=worker_log, samples=samples, vm_pid=sampler.vm_pid,
                system_start=system_start, system_end=system_snapshot())
        finally:
            # A boot left early, when the kit is stopped from outside, still
            # stops its guest and the log stream.
            for process in (host, log.process):
                if process.poll() is None:
                    process.terminate()
                    process.wait()
