"""Escape checks (docs/release.md, item 4, for its gates "Network escape",
"Conversation separation" and "Host and guest"): a hostile agent, running
commands as the agent in the reference sandbox, tries to get out, and each
attempt fails or reaches only what the design gives it. docs/plan.md,
"Escape checks", says what meets each attempt.

    llama-worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_escape_path.py

The file boots the guest twice, each boot shared by the checks that read it,
and each with a payment disk of its own, on which the payer, cloak-pay with
the real companion, starts (guest/pay/). The first has the payer's user
write stand-ins for its files on the disk, then runs plain commands in the
sandbox, one case each, with cover off and the stand-in tor (fake_tor.py),
which notes each connection's SOCKS identity and destination and refuses it,
so its log lists only what the attempts cause. The second is a serving
guest, whose runner runs Pi's tools in two conversations on the stand-in
door's scripted answers (tests/door_answers.json).
"""

import hashlib
import json
import re
import socket
import threading
from pathlib import Path

import pytest
from guest_boot import (ADDRESS, DEPLOYMENT, NOTE, PAY_HOME, PAY_LOG, Disk, Serving, boot, box_pass, events, fake_tor,
                        outputs, pay, pay_files, pay_marker, routes, sandbox, task, wait_for, write_pay_files)

OUTSIDE = "93.184.215.14"
OUTSIDE_V6 = "2606:2800:21f:cb07:6820:80da:af6b:8b2c"
# The guest's Tor port, by busybox's static nc, which torsocks never loads into.
NC = "busybox nc -w 3 127.0.0.1 9050"
# A SOCKS5 request to connect to OUTSIDE, port 443.
CONNECT = bytes([5, 1, 0, 1]) + socket.inet_aton(OUTSIDE) + (443).to_bytes(2, "big")
# tor's refusal (general failure), in the form the host's relay passes on.
REFUSED = bytes([5, 1, 0, 1]) + bytes(6)
# An identity of the agent's own, and a guess in the form of the daemon's:
# 32 random bytes in hex, with "x" for the password
# (zkapi-clientd/internal/relay/socks5.go at the pinned commit).
CHOSEN = b"agent-picked"
GUESS = b"0123456789abcdef" * 4
# The key Pi holds for the daemon (reference/wrapper/models.json).
PI_KEY = "Authorization: Bearer local"
READS = ["/run/cloak/rewriter-key", "/run/cloak/adapter-token", "/etc/cloak/cover.json", "/etc/cloak/model"]
# The guest's own /etc folders and file the sandbox binds, the daemon's cover
# list, the reference wrapper (bound read-only) and /usr/bin; each opened to
# append, which adds nothing where it opens.
WRITES = ["/etc/ssl/certs/probe", "/etc/ca-certificates/probe", "/etc/alternatives/probe", "/etc/ld.so.cache",
          "/etc/cloak/cover.json", "/opt/cloak/wrapper/sandbox", "/opt/cloak/wrapper/probe", "/usr/bin/probe",
          "/usr/bin/busybox"]
# The payment disk (guest/image/pay-disk): the payer's files on it, the
# companion's among them, the raw disk, the opened disk's device-mapper
# nodes, device-mapper's control and the key's boot file; and the disk's
# mount point and device folders, listed.
PAY_MARKER = pay_marker()
DISK_READS = [f"{PAY_HOME}/{path}" for path in (ADDRESS, NOTE, DEPLOYMENT)] + [
    "/dev/vda", "/dev/mapper/cloak-pay", "/dev/dm-0", "/dev/mapper/control", "/run/cloak/pay-disk-key"]
DISK_LISTS = [PAY_HOME, "/dev/mapper", "/sys/block"]


def frame(kind: bytes, payload: dict) -> bytes:
    """A whole frame for cloak-pay, as the Mac would send it: the kind, a
    four-byte big-endian length, then the payload (guest/pay/zz_cloak_pay.go)."""
    data = json.dumps(payload).encode()
    return kind + len(data).to_bytes(4, "big") + data


# A chat request, a call to the money route that makes the payer's key, and
# a read of the deposit and the chain.
FRAMES = [frame(b"R", {"identity": "0123456789abcdef" * 4,
                       "body": json.dumps({"model": "stand-in/model", "messages": [{"role": "user", "content": "Hello."}]})}),
          frame(b"C", {"method": "GET", "path": "/admin/funding/address", "body": ""}),
          frame(b"V", {"chain": True})]
# The guest's own loopback vsock address, the host, and the address the Mac
# gives the guest.
CIDS = [1, 2, 3]
# A guess at the bridge token cloak-pay gives its companion: 32 random bytes
# in hex, as the daemon makes it (zkapi-clientd/internal/config at the pinned
# mainnet commit).
BRIDGE_GUESS = "Authorization: Bearer " + "0123456789abcdef" * 4
# A device node of the sandbox's own for the raw disk and the opened disk,
# made from the numbers the kernel lists for each, then read.
NODES = ("for disk in vda dm-0; do "
         "set -- $(awk -v name=$disk '$4 == name { print $1, $2 }' /proc/partitions); "
         'echo "listed $disk $1:$2"; '
         'mknod /tmp/$disk b $1 $2 > /dev/null 2>&1; echo "mknod $disk $?"; '
         'cat /tmp/$disk > /dev/null 2>&1; echo "read $disk $?"; done')


def octal(data: bytes) -> str:
    return "".join(f"\\{byte:03o}" for byte in data)


def hexes(data: bytes) -> list[str]:
    return [f"{byte:02x}" for byte in data]


def socks(data: bytes) -> str:
    """Sends the bytes to the guest's Tor port and holds the connection 2 s
    for the answer, whose bytes it prints in hex."""
    return f"(printf '{octal(data)}'; sleep 2) | {NC} | od -An -tx1"


def user_password(user: bytes, password: bytes) -> bytes:
    """A SOCKS5 greeting that offers only a user name and password, then
    those (RFC 1929)."""
    return bytes([5, 1, 2, 1, len(user)]) + user + bytes([len(password)]) + password


def identity(user: bytes, password: bytes) -> str:
    """The identity the stand-in tor notes for this user name and password."""
    return hashlib.sha256(user + b"\0" + password).hexdigest()[:16]


def status(method: str, url: str, *headers: str) -> str:
    """curl with torsocks taken off: prints one request's HTTP status, or
    000 if nothing answered."""
    flags = "".join(f" -H '{header}'" for header in headers)
    return f"env -u LD_PRELOAD curl -s -o /dev/null -w '%{{http_code}}\\n' --max-time 5 -X {method}{flags} {url}"


def tried(paths: list[str], attempt: str) -> str:
    """The attempt on each path, then its exit status."""
    return "; ".join(f'{attempt.format(path)} > /dev/null 2>&1; echo "{path} $?"' for path in paths)


def statuses(output: str) -> list[tuple[str, str]]:
    return [tuple(line.rsplit(" ", 1)) for line in output.splitlines()]


def escaped(data: bytes) -> str:
    """The bytes as Go escapes, which cloak-vsock-probe reads."""
    return "".join(f"\\x{byte:02x}" for byte in data)


# Node sends one UDP datagram to OUTSIDE, port 443, as QUIC would, and prints
# "udp sent" or why it could not.
UDP = ("node -e 'const s = require(\"dgram\").createSocket(\"udp4\"); "
       "const end = e => { console.log(\"udp\", e ? e.code : \"sent\"); process.exit() }; "
       f"s.on(\"error\", end); s.send(\"x\", 443, \"{OUTSIDE}\", end)'")

ATTEMPTS = [
    # The payer's user, outside the sandbox: cloak-pay's log, which says its
    # companion answered, then its files written on the disk and read back
    # with the disk's line in the mount table.
    pay("payer", f"cat {PAY_LOG}"),
    write_pay_files("payment files", pay_files(PAY_MARKER)),
    pay("payer reads", f"grep ' {PAY_HOME} ' /proc/mounts; for file in {ADDRESS} {NOTE}; do cat $file; echo; done"),
    # The guest's network, which the sandbox shares: what listens on it.
    sandbox("listeners", 'for t in tcp tcp6 udp udp6; do echo "== $t"; cat /proc/net/$t; done'),
    # The Tor port without torsocks: SOCKS5 by hand, with no identity, with
    # one of the agent's choosing and with a guess at the daemon's.
    sandbox("tor port", socks(bytes([5, 1, 0]) + CONNECT)),
    sandbox("chosen identity", socks(user_password(CHOSEN, b"x") + CONNECT)),
    sandbox("guessed identity", socks(user_password(GUESS, b"x") + CONNECT)),
    # The adapter and the daemon without torsocks, with no key and with Pi's.
    sandbox("adapter", "; ".join([
        status("POST", "http://127.0.0.1:8012/v1/chat/completions"),
        status("POST", "http://127.0.0.1:8012/v1/chat/completions", PI_KEY),
        status("GET", "http://127.0.0.1:8012/v1/chat/completions"),
        status("GET", "http://127.0.0.1:8012/v1/models")])),
    sandbox("daemon", "; ".join([
        status("GET", "http://127.0.0.1:8787/admin/status"),
        status("GET", "http://127.0.0.1:8787/admin/status", PI_KEY),
        status("GET", "http://127.0.0.1:8787/admin/funding/address", PI_KEY),
        status("POST", "http://127.0.0.1:8787/admin/funding/deposit", PI_KEY, "X-OA-Management-Token: local"),
        status("POST", "http://127.0.0.1:8787/admin/withdrawal", PI_KEY, "X-OA-Management-Token: local")])),
    # The payer: its companion's port, with no token and with a guessed one,
    # and cloak-pay's vsock port, with a whole frame of each kind the Mac
    # sends from each address the sandbox can try.
    sandbox("companion port", "; ".join([
        status("GET", "http://127.0.0.1:8790/wallet/status"),
        status("GET", "http://127.0.0.1:8790/wallet/status", BRIDGE_GUESS),
        status("POST", "http://127.0.0.1:8790/oa/v1/lease", BRIDGE_GUESS, "Content-Type: application/json")])),
    sandbox("pay port", "; ".join(f"cloak-vsock-probe 8021 '{escaped(data)}' {cid}" for data in FRAMES for cid in CIDS)),
    # The Mac over vsock, on the door's port (open only while the guest
    # serves) and on the port numbers of the guest's own sender and runner.
    sandbox("vsock", "for port in 8742 8020 8030; do cloak-vsock-probe $port x; done"),
    # The guest's secrets and settings, and its programs.
    sandbox("reads", tried(READS, "cat {}") + "; " + tried(["/run/cloak-runner"], "ls {}")),
    sandbox("writes", tried(WRITES, "(: >> {})")),
    sandbox("symlink", 'ln -s /run/cloak/rewriter-key /workspace/key; echo "link $?"; '
                       'cat /workspace/key > /dev/null 2>&1; echo "read $?"; rm /workspace/key'),
    # The payment disk, and the keys the kernel holds that the sandbox can see.
    sandbox("disk reads", tried(DISK_READS, "cat {}") + "; " + tried(DISK_LISTS, "ls {}")),
    sandbox("disk nodes", NODES),
    sandbox("keys", "cat /proc/keys"),
    # Other ways out.
    sandbox("dns over tcp", "busybox nc -w 3 8.8.8.8 53 < /dev/null 2>&1; echo $?"),
    sandbox("udp", f"{UDP}; env -u LD_PRELOAD {UDP}"),
    sandbox("ipv6", f"busybox nc -w 3 {OUTSIDE_V6} 443 < /dev/null 2>&1; echo $?"),
    sandbox("ping", f'busybox ping -c 1 -W 2 {OUTSIDE} 2>&1; echo "exit $?"; '
                    f'busybox ping6 -c 1 -W 2 {OUTSIDE_V6} 2>&1; echo "exit $?"'),
    sandbox("unix sockets", "cat /proc/net/unix"),
    # A child in a session of its own that ignores hang-ups, holds no output
    # and writes to the workspace each second; the next case watches it.
    sandbox("outlive", "setsid sh -c 'trap \"\" HUP INT TERM; while :; do echo x >> /workspace/alive; sleep 1; done' "
                       "< /dev/null > /dev/null 2>&1 & sleep 3; wc -c < /workspace/alive"),
    sandbox("after", "a=$(wc -c < /workspace/alive); sleep 3; b=$(wc -c < /workspace/alive); echo $a $b"),
]


@pytest.fixture(scope="module")
def attempts(tmp_path_factory) -> tuple[dict[str, str], list[dict], Path]:
    """Each attempt's output, every connection the stand-in tor saw, and the
    folder where the stand-in worker keeps each request it gets."""
    folder = tmp_path_factory.mktemp("attempts")
    results, _ = boot(folder, ATTEMPTS, fake_tor(folder, "ready"), disk=Disk.blank(folder))
    return {name: r["output"] for name, r in results.items()}, routes(folder), folder


def test_loopback_holds_three_services_and_nothing_takes_udp(attempts):
    out, _, _ = attempts
    tables: dict[str, list[tuple[str, str]]] = {}
    for line in out["listeners"].splitlines():
        if line.startswith("== "):
            table = tables.setdefault(line[3:], [])
        elif (fields := line.split()) and fields[0].rstrip(":").isdigit():
            table.append((fields[1], fields[3]))
    # Local address and port in hex; state 0A is listening. The payer's
    # listeners, its companion's, its CONNECT proxy's and its own Tor port's,
    # are in its own network namespace.
    listening = {(local.split(":")[0], int(local.split(":")[1], 16))
                 for name in ("tcp", "tcp6") for local, state in tables[name] if state == "0A"}
    assert listening == {("0100007F", 8012), ("0100007F", 8787), ("0100007F", 9050)}, out["listeners"]
    assert tables["udp"] == tables["udp6"] == [], out["listeners"]


def test_the_tor_port_without_torsocks_takes_a_socks_request_to_tor(attempts):
    out, seen, _ = attempts
    # The greeting is answered with no authentication, the request with tor's refusal.
    assert out["tor port"].split() == hexes(bytes([5, 0]) + REFUSED)
    # tor saw the three requests made to the Tor port by hand, each for the
    # destination it named, and nothing else in the boot reached it, the
    # payer and the frames sent to it included.
    destination = f"{OUTSIDE}:443"
    assert seen == [{"identity": "none", "destination": destination},
                    {"identity": identity(CHOSEN, b"x"), "destination": destination},
                    {"identity": identity(GUESS, b"x"), "destination": destination}]


def test_an_agent_picks_its_own_tor_identity(attempts):
    """Any user name and password reach tor as they were sent, so a program
    in the sandbox can take any identity, a guess at another's included; the
    daemon's is 32 random bytes, which a guess does not find."""
    out, seen, _ = attempts
    for name in ["chosen identity", "guessed identity"]:
        assert out[name].split() == hexes(bytes([5, 2, 1, 0]) + REFUSED), name
    assert [r["identity"] for r in seen[1:]] == [identity(CHOSEN, b"x"), identity(GUESS, b"x")]


def test_the_adapter_and_the_daemon_refuse_pis_key_and_no_key(attempts):
    out, _, folder = attempts
    # The adapter takes only a POST to its one route with the rewriter key.
    assert out["adapter"].split() == ["401", "401", "405", "404"]
    # Outside its two inference routes, which take any local request, the
    # daemon takes only its own key, made at its start.
    assert out["daemon"].split() == ["401"] * 5
    # Nothing reached the worker.
    assert not (folder / "1.json").exists()


def test_the_sandbox_reaches_neither_the_companion_nor_cloak_pay(attempts):
    out, _, _ = attempts
    # cloak-pay runs, and read the wallet through its companion.
    assert [line.split(" ", 3)[3] for line in out["payer"].splitlines()] == ["wallet: no note"], out["payer"]
    # Nothing answers the companion's port in the sandbox's network, with no
    # token or a guessed one.
    assert out["companion port"].split() == ["000"] * 3, out["companion port"]
    # Each frame to cloak-pay's vsock port was refused or closed unanswered.
    lines = out["pay port"].splitlines()
    assert len(lines) == len(FRAMES) * len(CIDS), lines
    assert all(line.startswith(("refused", "closed, no answer")) for line in lines), lines


def test_the_mac_answers_no_vsock_port_the_sandbox_tries(attempts):
    out, _, _ = attempts
    lines = out["vsock"].splitlines()
    assert len(lines) == 3, lines
    assert all(line.startswith(("refused", "closed, no answer")) for line in lines), lines


def test_the_guests_secrets_settings_and_programs_cannot_be_read_or_changed(attempts):
    out, _, _ = attempts
    reads, writes = statuses(out["reads"]), statuses(out["writes"])
    assert [path for path, _ in reads] == READS + ["/run/cloak-runner"]
    assert [path for path, _ in writes] == WRITES
    assert all(code != "0" for _, code in reads + writes), reads + writes
    # A link made in the workspace leads nowhere the sandbox cannot already go.
    (_, link), (_, read) = statuses(out["symlink"])
    assert link == "0" and read != "0"


def test_the_payment_disk_its_files_and_its_key_cannot_be_reached(attempts):
    out, _, _ = attempts
    # The payer's files are on the opened disk, mounted at its home, and
    # hold the marker.
    assert out["payment files"] == "", out["payment files"]
    mount, *files = out["payer reads"].splitlines()
    assert mount.startswith(f"/dev/mapper/cloak-pay {PAY_HOME} ext4 "), out["payer reads"]
    assert files == list(pay_files(PAY_MARKER).values()), out["payer reads"]
    # The sandbox reads and lists none of the disk, its devices or its key.
    reads, lists = statuses(out["disk reads"])[:len(DISK_READS)], statuses(out["disk reads"])[len(DISK_READS):]
    assert [path for path, _ in reads] == DISK_READS and [path for path, _ in lists] == DISK_LISTS
    assert all(code != "0" for _, code in reads + lists), out["disk reads"]
    # The kernel lists both disks' numbers, and the sandbox can make a node
    # for neither, nor read one.
    nodes = [line.split() for line in out["disk nodes"].splitlines()]
    assert [line[:2] for line in nodes] == [[step, disk] for disk in ("vda", "dm-0")
                                            for step in ("listed", "mknod", "read")], out["disk nodes"]
    assert all(re.fullmatch(r"\d+:\d+", line[2]) for line in nodes if line[0] == "listed"), out["disk nodes"]
    assert all(line[2] != "0" for line in nodes if line[0] != "listed"), out["disk nodes"]
    # No key of cryptsetup's is in the keys the sandbox can see.
    assert "cryptsetup" not in out["keys"], out["keys"]
    # Nothing the sandbox printed holds the marker.
    assert all(PAY_MARKER not in output for name, output in out.items() if name not in ("payment files", "payer reads"))


def test_dns_over_tcp_udp_and_ipv6_reach_nothing(attempts):
    out, _, _ = attempts
    for name in ["dns over tcp", "ipv6"]:
        assert "Network is unreachable" in out[name] and out[name].split()[-1] != "0", out[name]
    # Under torsocks, then without it.
    udp = [line.split()[1] for line in out["udp"].splitlines() if line.startswith("udp ")]
    assert len(udp) == 2 and "sent" not in udp and udp[1] == "ENETUNREACH", out["udp"]


def test_ping_reaches_nothing(attempts):
    out, _, _ = attempts
    exits = [line.split()[1] for line in out["ping"].splitlines() if line.startswith("exit ")]
    assert len(exits) == 2 and "0" not in exits, out["ping"]


def test_no_abstract_unix_socket_is_open_in_the_guest(attempts):
    out, _, _ = attempts
    # Abstract names belong to the network namespace, which the sandbox shares.
    rows = [line.split() for line in out["unix sockets"].splitlines()[1:]]
    assert [row[7] for row in rows if len(row) > 7 and row[7].startswith("@")] == [], out["unix sockets"]


def test_a_child_does_not_outlive_its_case(attempts):
    out, _, _ = attempts
    written = int(out["outlive"].split()[-1])
    before, after = (int(n) for n in out["after"].split())
    # The child wrote while its case ran, and nothing in the 3 s the next
    # case watched: it ended with its case.
    assert written > 0
    assert before == after >= written


EXITED = {"exited": {"status": 0, "signalled": False}}


def tool_output(ran: list[dict]) -> str:
    """The text of the task's one tool's result."""
    ended = [e for e in outputs(ran) if e["type"] == "tool_execution_end"]
    assert [e["toolName"] for e in ended] == ["bash"], ran
    return ended[0]["result"]["content"][0]["text"]


@pytest.fixture(scope="module")
def conversations(tmp_path_factory) -> dict:
    """Two conversations in one serving guest. s-b holds a task open (its
    tool holds two connections to the door) while a task in s-a runs "peek",
    which looks for s-b's folders and its task's copy of the wrapper, and
    prints every models.json it can find. Then s-a's tool runs "plant",
    which moves its home's .pi folder aside and leaves a link to s-b's
    workspace in its place (it cannot remove the folder: the file Pi reads
    there is a mount point while the task runs); s-a starts one more task;
    and s-b runs "peek" in turn. The sandbox binds the task's models.json,
    its pass inside, read-only where Pi reads it in the home, and bubblewrap
    makes that mount point inside the sandbox's own root
    (reference/wrapper/sandbox)."""
    serving = Serving(tmp_path_factory.mktemp("conversations"))
    a, b = box_pass(), box_pass()
    try:
        serving.door.plans[b] = ["hold"]
        held = serving.start(task("Hold two connections.", "s-b", b))
        holding: list[dict] = []
        reader = threading.Thread(target=lambda: holding.extend(events(held)))
        reader.start()
        wait_for(lambda: len(serving.door.silent()) == 2, 600, "s-b's tool did not hold its connections")
        serving.door.plans[a] = ["peek", "final"]
        peeked = serving.run(task("Look around.", "s-a", a))
        held.shutdown(socket.SHUT_WR)
        reader.join(30)
        assert not reader.is_alive()
        serving.door.plans[a] = ["plant", "final"]
        planted = serving.run(task("Tidy your home.", "s-a", a))
        # No answer is planned: only the sandbox's start matters.
        serving.door.plans[a] = []
        started = serving.run(task("Start again.", "s-a", a))
        serving.door.plans[b] = ["peek", "final"]
        looked = serving.run(task("Look around.", "s-b", b))
    finally:
        serving.close()
    return {"a": a, "b": b, "peeked": peeked, "sent": serving.door.asked(a), "planted": planted, "started": started,
            "looked": looked}


def test_a_tool_cannot_reach_another_conversations_files_or_pass(conversations):
    c = conversations
    assert c["peeked"][-1] == EXITED, c["peeked"]
    seen = tool_output(c["peeked"])
    listed = [line.split() for line in seen.splitlines() if line.startswith("list ")]
    assert [path for _, path, _ in listed] == ["/home/agent/conversations", "/home/agent/conversations/s-b",
                                               "/run/cloak-runner/s-b"]
    assert all(code != "0" for _, _, code in listed), seen
    # Of the tasks' copies of the wrapper, the sandbox holds its own only.
    assert "copies: s-a" in seen.splitlines()
    # It read its own pass; s-b's, in use at that moment, is nowhere in what
    # it saw or sent.
    assert c["a"] in seen
    assert c["b"] not in json.dumps(c["peeked"])
    assert all(c["b"] not in r["body"] for r in c["sent"])


def test_a_tool_cannot_make_a_later_task_write_into_another_conversation(conversations):
    """Found 19 November: the sandbox script copied the task's models.json
    into the home before bubblewrap, as the agent user, who owns every
    conversation's folders, following the link, so s-b's tool found s-a's
    pass in its workspace. Now bubblewrap resolves the link inside s-a's
    sandbox, which holds no s-b, and s-a's next task does not start."""
    c = conversations
    assert "planted 0" in tool_output(c["planted"]).splitlines()
    # bubblewrap refused the link before Pi started.
    assert c["started"][-1] == {"exited": {"status": 1, "signalled": False}}, c["started"]
    assert outputs(c["started"]) == [], c["started"]
    assert c["looked"][-1] == EXITED, c["looked"]
    looked = tool_output(c["looked"])
    assert c["b"] in looked
    assert c["a"] not in looked
