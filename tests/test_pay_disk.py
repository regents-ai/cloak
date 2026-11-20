"""The payment disk on the guest (guest/image/pay-disk; docs/plan.md, "The
encrypted disk"): the guest's one disk, an image file on the Mac encrypted
under 32 bytes the host gives, which the guest opens for the payer's user
alone. Every image here is a temporary one and every key 32 random bytes
made here; each boot has the stand-in worker and tor.

    llama-worker/install.sh
    guest/build.sh
    host/build.sh
    uv run --with pytest==8.4.2 pytest tests/test_pay_disk.py

The first boot makes the disk, the payer's user writes stand-ins for its
files there, each to a temporary name renamed into place, and the host is
killed (SIGKILL) as soon as that case's result is on the console, while the
next case holds the guest running, so nothing stops cleanly. The second
boot opens the same disk and reads the files back. Then the disk is booted
with a wrong key, with both copies of its header damaged (on a copy), and
called new once more: each ends the guest before any case runs, saying why,
with the image unchanged. Last, the image is searched for the marker every
stand-in holds. guest/image/pay-disk-check.sh checks the same program in
Docker, with the image copied at the moment the files are renamed into place
and more kinds of damage.
"""

import hashlib
import json
import secrets
import shutil
from pathlib import Path

import pytest
from guest_boot import ADDRESS, JOURNAL, NOTE, PAY_HOME, Disk, fake_tor, pay, pay_files, run, write_pay_files

MARKER = "cloak-at-rest-" + secrets.token_hex(16)
FILES = pay_files(MARKER)
READ = pay("read", f"grep ' {PAY_HOME} ' /proc/mounts; for file in {ADDRESS} {NOTE} {JOURNAL}; do cat $file; echo; done")
OPEN = "cloak-guest: payment disk open"
STOP = "cloak-guest: payment disk did not open: "


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def result(console: str, name: str) -> dict | None:
    """The case's result, once the console holds all of its line."""
    for line in console.splitlines(keepends=True):
        if line.startswith('{"name":' + json.dumps(name)) and line.endswith("\n"):
            return json.loads(line)
    return None


def boot(folder: Path, cases: list[dict], disk: Disk) -> str:
    """One boot to its end; the guest's console."""
    console, err, returncode = run(folder, cases, fake_tor(folder, "ready"), disk=disk)
    assert returncode == 0, err
    return console


def refused(folder: Path, disk: Disk) -> tuple[str, str, str]:
    """A boot of a disk that does not open: the guest's console, and the
    image's digest before and after."""
    before = digest(disk.image)
    return boot(folder, [READ], disk), before, digest(disk.image)


@pytest.fixture(scope="module")
def boots(tmp_path_factory) -> dict:
    folder = {name: tmp_path_factory.mktemp(name) for name in ("first", "second", "wrong", "damaged", "again")}
    disk = Disk.blank(folder["first"])
    first, _, _ = run(folder["first"], [write_pay_files("write", FILES), pay("hold", "sleep 600")],
                      fake_tor(folder["first"], "ready"), disk=disk,
                      until=lambda console: result(console, "write") is not None)
    disk.new = False
    second = boot(folder["second"], [READ], disk)
    wrong_key = folder["wrong"] / "wrong.key"
    wrong_key.write_bytes(secrets.token_bytes(32))
    wrong = refused(folder["wrong"], Disk(disk.image, wrong_key, False))
    damaged_image = folder["damaged"] / "pay-disk.img"
    shutil.copyfile(disk.image, damaged_image)
    # Both copies of the LUKS2 header, 16 KiB each, at the image's start.
    with damaged_image.open("r+b") as image:
        image.write(secrets.token_bytes(32 << 10))
    damaged = refused(folder["damaged"], Disk(damaged_image, disk.key, False))
    again = refused(folder["again"], Disk(disk.image, disk.key, True))
    return {"first": first, "second": second, "wrong": wrong, "damaged": damaged, "again": again, "image": disk.image}


def test_a_disk_cut_off_after_its_files_were_written_opens_with_each_file_as_written(boots):
    first, second = boots["first"], boots["second"]
    assert OPEN in first and result(first, "write")["exit"] == 0, first
    # The host was killed while the next case held the guest running.
    assert result(first, "hold") is None and "agent check exited" not in first, first
    assert OPEN in second and result(second, "read")["exit"] == 0, second
    mount, *files = result(second, "read")["output"].splitlines()
    device, point, kind, options = mount.split()[:4]
    assert (device, point, kind) == ("/dev/mapper/cloak-pay", PAY_HOME, "ext4"), mount
    assert {"sync", "nosuid", "nodev", "noexec"} <= set(options.split(",")), mount
    assert files == list(FILES.values())
    # The journal reads, in upstream's shape.
    assert json.loads(files[2]) == json.loads(FILES[JOURNAL])


@pytest.mark.parametrize("boot_name, reason", [
    ("wrong", "No key available with this passphrase."),
    ("damaged", "Device /dev/vda is not a valid LUKS device."),
    ("again", "the new image is not blank"),
])
def test_a_disk_that_does_not_open_ends_the_guest_and_is_left_as_it_was(boots, boot_name, reason):
    console, before, after = boots[boot_name]
    assert STOP + reason in console, console
    assert OPEN not in console and result(console, "read") is None, console
    assert before == after


def test_the_image_holds_none_of_what_was_written_inside_it(boots):
    # Read through the opened disk, the files hold the marker; the image
    # on the Mac holds none of it.
    assert MARKER in result(boots["second"], "read")["output"]
    assert MARKER.encode() not in boots["image"].read_bytes()
