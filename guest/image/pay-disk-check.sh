#!/bin/sh
# Checks the payment disk program (guest/image/pay-disk) on Linux's own loop
# devices, device-mapper and ext4, in the guest build image guest/build.sh
# makes, so with the guest's cryptsetup and mke2fs and its busybox for
# everything else. The kernel is Docker's, not the guest's: the guest's own
# boot, modules and Mac-side sync are tests/test_pay_disk.py's. The container
# has no network, two cores, 1 GB and a 768 MB scratch folder in memory. It
# may mount, and use loop and device-mapper devices and no other, so it can
# open no other disk; Docker's system call filter is off, as it refuses the
# kernel keyring, where cryptsetup keeps the disk's key, as it does in the
# guest. Every key is random bytes made for the run; no real key is read.
#
#   sh guest/image/pay-disk-check.sh
#
# What a guest killed at any moment keeps is checked by copying the image
# while its disk is open and a payment file has just been renamed into place,
# as a cut would leave it, then opening the copy.
set -eu
cd "$(dirname "$0")"
docker run --rm -i --pull never --network none --cpus 2 --memory 1g --tmpfs /work:size=768m \
	--cap-add SYS_ADMIN --security-opt seccomp=unconfined --device /dev/loop-control --device /dev/mapper/control \
	--device-cgroup-rule 'b 7:* rmw' --device-cgroup-rule 'b 253:* rmw' \
	-v "$PWD:/src:ro" cloak-guest-build /bin/busybox sh -s <<'INSIDE'
set -eu
# pay-disk finds busybox's tools first, as in the guest; this script names
# GNU's cp, grep and setpriv where it needs theirs.
mkdir /work/bin
/bin/busybox --install -s /work/bin
export PATH=/work/bin:/usr/sbin:/usr/bin
passed=0
fail() { echo "FAIL: $*"; exit 1; }
pass() { passed=$((passed + 1)); echo "ok: $*"; }

# A loop device for an image; only a loop device is ever handed to pay-disk.
loops=
attach() {
	device=$(losetup -f)
	case $device in /dev/loop[0-9]*) ;; *) fail "no free loop device: $device" ;; esac
	[ -b "$device" ] || mknod "$device" b 7 "${device#/dev/loop}"
	losetup "$device" "$1"
	loops="$loops $device"
}
detach() {
	umount /work/mnt 2>/dev/null || true
	cryptsetup close cloak-pay 2>/dev/null || true
	losetup -d "$device"
}
cleanup() {
	umount /work/mnt 2>/dev/null || true
	cryptsetup close cloak-pay 2>/dev/null || true
	for loop in $loops; do losetup -d "$loop" 2>/dev/null || true; done
}
trap cleanup EXIT

disk() { /bin/busybox sh /src/pay-disk "$@"; }
digest() { sha256sum "$1" | cut -d' ' -f1; }
# The disk's line in the mount table, or nothing.
mounted() { grep '^/dev/mapper/cloak-pay /work/mnt ' /proc/mounts || true; }

head -c 32 /dev/urandom > /work/key
head -c 32 /dev/urandom > /work/wrong-key
# The guest's mount point: root's, closed to everyone else until the disk
# is mounted over it.
mkdir -m 0700 /work/mnt
marker=cloak-at-rest-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')

# The files the payer's programs write, with the payer's home on the disk
# (docs/plan.md, "The encrypted disk"): the companion's write-ahead journal
# and note (its note secret), and the daemon's payment address (its signing
# key). Stand-in contents, each carrying the marker.
state=.config/zkapi-clientd
note_dir=$state/zkapi/mainnet/zkapi-native-eth-mainnet-note-bound-v1-fresh-20260930
journal=$note_dir/pending_journal.json
note=$note_dir/note_state.json
address=$state/funding/mainnet/address-funding.json
mkdir -p /work/expected
printf '{"exists":true,"client_request_id":"%s-request","nullifier":"0x2","payload_hash":"0x3","user_rerandomization":"0x1","created_at_ms":1}' \
	"$marker" > /work/expected/journal
printf '{"note_id":7,"secret_s":"%s-note-secret","current_balance":1000}' "$marker" > /work/expected/note
printf '{"version":1,"address":"0x0","private_key":"%s-signing-key","phase":"ready"}' "$marker" > /work/expected/address

# As the payer, each file written to a temporary name and renamed into
# place, as upstream writes them, with no fsync (zkapi-client's journal.rs
# and note_state.rs at the pinned protocol commit).
write_payment_files() {
	/usr/bin/setpriv --reuid=1009 --regid=1009 --clear-groups /bin/busybox sh -euc '
		cd /work/mnt
		mkdir -p -m 0700 .config .config/zkapi-clientd .config/zkapi-clientd/zkapi .config/zkapi-clientd/zkapi/mainnet \
			'"$note_dir"' .config/zkapi-clientd/funding .config/zkapi-clientd/funding/mainnet
		for pair in journal:'"$journal"' note:'"$note"' address:'"$address"'; do
			name=${pair%%:*} path=${pair#*:}
			cat /work/expected/$name > $path.tmp
			mv $path.tmp $path
		done'
}

# 1. A blank image the host has not called new: not formatted.
truncate -s 64M /work/disk.img
attach /work/disk.img
before=$(digest /work/disk.img)
if out=$(disk open "$device" /work/key /work/mnt); then fail "a blank image opened: $out"; fi
case $out in *"not a valid LUKS device"*) ;; *) fail "unexpected reason: $out" ;; esac
[ "$(digest /work/disk.img)" = "$before" ] || fail "the blank image changed"
[ -z "$(mounted)" ] || fail "something was mounted"
pass "a blank image the host did not call new stops ($out) and is unchanged"

# 2. Made new: LUKS2, ext4 mounted with sync, the payer's alone.
disk create "$device" /work/key /work/mnt || fail "create failed"
cryptsetup isLuks --type luks2 "$device" || fail "not LUKS2"
line=$(mounted)
for option in rw nosuid nodev noexec sync; do
	case ",$(echo "$line" | cut -d' ' -f4)," in *",$option,"*) ;; *) fail "mount option $option missing: $line" ;; esac
done
[ "$(echo "$line" | cut -d' ' -f3)" = ext4 ] || fail "not ext4: $line"
[ "$(stat -c %u:%g:%a /work/mnt)" = 1009:1009:700 ] || fail "mount point is $(stat -c %u:%g:%a /work/mnt)"
pass "a new image is made LUKS2 with ext4 mounted sync,nosuid,nodev,noexec, the payer's alone (1009, 0700)"

# Each payment file is in the open disk at $1 as written.
files_as_written() {
	for name in journal note address; do
		eval path=\$$name
		cmp -s /work/expected/$name "$1/$path" || fail "$path is not as written"
	done
}

# 3. A payment file written, then the guest cut off at once: the image as
# the device holds it, copied while the disk is still open.
write_payment_files
/usr/bin/cp --sparse=always /work/disk.img /work/cut.img
detach
attach /work/cut.img
disk open "$device" /work/key /work/mnt || fail "the cut image did not open"
files_as_written /work/mnt
pass "a disk cut off just after its payment files were renamed into place opens with each file as written"

# 4. At rest: none of the marker in either image, though the search finds
# it on the open disk.
/usr/bin/grep -a -q -F "$marker" /dev/mapper/cloak-pay || fail "the marker is not on the open disk"
detach
for image in /work/disk.img /work/cut.img; do
	if /usr/bin/grep -a -q -F "$marker" $image; then fail "the marker is in $image"; fi
done
pass "neither image holds the marker written inside it, which the search finds on the open disk"

# 5. A wrong key: a stop, the image unchanged.
attach /work/disk.img
before=$(digest /work/disk.img)
if out=$(disk open "$device" /work/wrong-key /work/mnt); then fail "a wrong key opened it"; fi
case $out in *"No key available with this passphrase"*) ;; *) fail "unexpected reason: $out" ;; esac
[ "$(digest /work/disk.img)" = "$before" ] || fail "the image changed"
[ -z "$(mounted)" ] || fail "something was mounted"
pass "a wrong key stops ($out) and the image is unchanged"

# 6. The host saying new for an image already made: refused, unchanged.
if out=$(disk create "$device" /work/key /work/mnt); then fail "a made image was formatted again"; fi
case $out in *"not blank"*) ;; *) fail "unexpected reason: $out" ;; esac
[ "$(digest /work/disk.img)" = "$before" ] || fail "the image changed"
pass "an image already made, called new, is refused ($out) and unchanged"
detach

# 7. One copy of the header damaged (the first 4 KiB): cryptsetup rewrites
# it from the other copy as it opens the disk, its own repair, and every
# payment file is as written.
/usr/bin/cp --sparse=always /work/disk.img /work/one-copy.img
dd if=/dev/urandom of=/work/one-copy.img bs=1024 count=4 conv=notrunc 2>/dev/null
attach /work/one-copy.img
disk open "$device" /work/key /work/mnt || fail "a disk with one good header copy did not open"
files_as_written /work/mnt
pass "a disk with one header copy damaged opens, repaired by cryptsetup from the other copy, with each file as written"
detach

# 8. Damaged headers: both copies (the first 32 KiB), and the keyslot
# holding the volume key (4 KiB at 32 KiB): a stop, no format, unchanged.
for damage in header:0 keyslot:32; do
	what=${damage%%:*} at=${damage#*:}
	/usr/bin/cp --sparse=always /work/disk.img /work/$what.img
	if [ $what = header ]; then count=32; else count=4; fi
	dd if=/dev/urandom of=/work/$what.img bs=1024 seek=$at count=$count conv=notrunc 2>/dev/null
	attach /work/$what.img
	before=$(digest /work/$what.img)
	if out=$(disk open "$device" /work/key /work/mnt); then fail "a damaged $what opened"; fi
	[ "$(digest /work/$what.img)" = "$before" ] || fail "the image with a damaged $what changed"
	[ -z "$(mounted)" ] || fail "something was mounted"
	pass "a damaged $what stops ($out) and the image is unchanged"
	detach
done

# 9. A damaged filesystem inside a good disk: a stop, no repair, unchanged.
/usr/bin/cp --sparse=always /work/disk.img /work/filesystem.img
attach /work/filesystem.img
cryptsetup open --type luks2 --key-file /work/key "$device" cloak-pay
dd if=/dev/urandom of=/dev/mapper/cloak-pay bs=1024 seek=1 count=1 conv=notrunc 2>/dev/null
cryptsetup close cloak-pay
before=$(digest /work/filesystem.img)
if out=$(disk open "$device" /work/key /work/mnt); then fail "a damaged filesystem mounted"; fi
[ "$(digest /work/filesystem.img)" = "$before" ] || fail "the image with a damaged filesystem changed"
[ -z "$(mounted)" ] && ! [ -e /dev/mapper/cloak-pay ] || fail "the disk was left open"
pass "a damaged filesystem stops ($out) and the image is unchanged"
detach

echo "passed $passed"
INSIDE
