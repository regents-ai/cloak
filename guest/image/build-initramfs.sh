#!/bin/sh
# Runs inside the pinned build image. Reads the guest binaries from /out and
# writes /out/Image (the uncompressed kernel), /out/initrd.gz (the guest root)
# and /out/guest-manifest.txt (what went into both, with hashes).
set -eu
kernel=$(ls /lib/modules)
root=$(mktemp -d)
chmod 0755 $root

# Debian's arm64 vmlinuz is already the uncompressed Image the Mac's boot
# loader takes ("ARMd" at byte 56).
image=/boot/vmlinuz-$kernel
[ "$(dd if=$image bs=1 skip=56 count=4 2>/dev/null)" = ARMd ]
cp $image /out/Image

mkdir -p $root/bin $root/usr/bin $root/lib/modules $root/proc $root/sys $root/dev $root/etc/cloak $root/run/cloak $root/tmp
cp /bin/busybox $root/bin/busybox
for module in vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport; do
	xz -dc $(find /lib/modules/$kernel -name "$module.ko.xz") > $root/lib/modules/$module.ko
done
install -m 0755 /out/cloak-adapter /out/cloak-rewrite-check $root/usr/bin/
install -m 0755 /src/init $root/init
cat > $root/etc/passwd <<PASSWD
root:x:0:0:root:/:/bin/sh
adapter:x:1001:1001:adapter:/:/bin/sh
checker:x:1002:1002:checker:/:/bin/sh
PASSWD
cat > $root/etc/group <<GROUP
root:x:0:
adapter:x:1001:
checker:x:1002:
rewriter:x:1003:adapter,checker
GROUP
chmod 0755 $root/run/cloak
chmod 1777 $root/tmp

(cd $root && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet) | gzip -n -9 > /out/initrd.gz

{
	dpkg-query -W linux-image-$kernel busybox-static
	cd /out && sha256sum Image initrd.gz cloak-adapter cloak-rewrite-check
} > /out/guest-manifest.txt
cat /out/guest-manifest.txt
