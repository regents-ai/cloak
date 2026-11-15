#!/bin/sh
# Runs inside the pinned build image. Reads the guest binaries from /out (the
# sender among them, the one dynamic Cloak program), the
# pinned Pi package from /pi, the pinned Node.js runtime from /node and the
# reference wrapper from /wrapper, and writes /out/Image (the uncompressed
# kernel), /out/initrd.gz (the guest root) and /out/guest-manifest.txt (what
# went into both, with hashes).
#
# The root keeps everything under /usr (bin, sbin and lib are links into it),
# because the reference sandbox gives the agent the guest's /usr read-only and
# links its own /bin and /lib into it.
set -eu
kernel=$(ls /lib/modules)
arch=aarch64-linux-gnu
root=$(mktemp -d)
chmod 0755 $root

# Debian's arm64 vmlinuz is already the uncompressed Image the Mac's boot
# loader takes ("ARMd" at byte 56).
image=/boot/vmlinuz-$kernel
[ "$(dd if=$image bs=1 skip=56 count=4 2>/dev/null)" = ARMd ]
cp $image /out/Image

mkdir -p $root/usr/bin $root/usr/sbin $root/usr/lib/$arch $root/usr/lib/modules $root/usr/lib/cloak \
	$root/usr/local/bin $root/usr/local/lib/node_modules/@earendil-works \
	$root/proc $root/sys $root/dev $root/tmp $root/newroot $root/run/cloak $root/home \
	$root/etc/cloak $root/etc/alternatives $root/etc/ld.so.conf.d $root/opt/cloak
ln -s usr/bin $root/bin
ln -s usr/sbin $root/sbin
ln -s usr/lib $root/lib

cp /bin/busybox $root/usr/bin/busybox
for module in vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport virtio-rng; do
	xz -dc $(find /lib/modules/$kernel -name "$module.ko.xz") > $root/usr/lib/modules/$module.ko
done
install -m 0755 /out/cloak-adapter /out/cloak-port /out/cloak-rewrite-check /out/cloak-daemon /out/cloak-agent-check \
	/out/cloak-runner /out/cloak-routing-probe /out/cloak-vsock-probe /out/cloak-sender $root/usr/bin/
install -m 0755 /src/init $root/init
install -m 0755 /src/boot $root/usr/lib/cloak/boot

# The reference wrapper and what it runs: bash, bubblewrap, torsocks, the CA
# certificates it binds, Node.js and Pi, installed where `npm install -g` puts it,
# and curl for the agent's tools.
# The torsocks script's Debian-only block warns when libtorsocks is missing
# for another enabled architecture, using dpkg tools the guest does not carry;
# the guest has one architecture, so the block is left out. The package's own
# loader file puts libtorsocks on the library path, as LD_PRELOAD names it bare.
install -m 0755 /bin/bash /usr/bin/bwrap /usr/bin/curl $root/usr/bin/
sed '/^# -- Debian specific part$/,/^# -- Debian specific part ended$/d' /usr/bin/torsocks > $root/usr/bin/torsocks
chmod 0755 $root/usr/bin/torsocks
if grep -q dpkg $root/usr/bin/torsocks; then echo 'torsocks: Debian block still present' >&2; exit 1; fi
cp -a /usr/lib/$arch/torsocks $root/usr/lib/$arch/
cp /etc/ld.so.conf.d/torsocks-$arch.conf $root/etc/ld.so.conf.d/
cp -a /etc/ssl /etc/ca-certificates $root/etc/
mkdir -p $root/usr/share/ca-certificates
cp -a /usr/share/ca-certificates/. $root/usr/share/ca-certificates/
cp -a /wrapper $root/opt/cloak/wrapper
tar -xJf /node/node-v24.22.2-linux-arm64.tar.xz -C /tmp
install -m 0755 /tmp/node-v24.22.2-linux-arm64/bin/node $root/usr/local/bin/node
mkdir -p $root/usr/local/share/doc/node
cp /tmp/node-v24.22.2-linux-arm64/LICENSE $root/usr/local/share/doc/node/
pi=$root/usr/local/lib/node_modules/@earendil-works/pi-coding-agent
mkdir $pi
tar -xzf /pi/earendil-works-pi-coding-agent-1.3.0.tgz -C $pi --strip-components 1 --no-same-owner
ln -s ../lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js $root/usr/local/bin/pi

# Shared libraries the dynamic programs need, from this image's glibc.
for elf in /bin/bash /usr/bin/bwrap /usr/bin/curl $root/usr/local/bin/node /usr/lib/$arch/torsocks/libtorsocks.so $root/usr/bin/cloak-sender; do
	ldd $elf | awk '/=>/ { print $3 } /ld-linux/ { print $1 }'
done | sort -u | while read -r library; do
	case $library in
	/lib/ld-linux-*|/usr/lib/ld-linux-*) cp -L $library $root/usr/lib/ ;;
	*) cp -L $library $root/usr/lib/$arch/ ;;
	esac
done
echo /usr/lib/$arch > $root/etc/ld.so.conf.d/$arch.conf
echo 'include /etc/ld.so.conf.d/*.conf' > $root/etc/ld.so.conf
ldconfig -r $root

cat > $root/etc/passwd <<PASSWD
root:x:0:0:root:/:/bin/sh
adapter:x:1001:1001:adapter:/:/bin/sh
checker:x:1002:1002:checker:/:/bin/sh
zkapi:x:1004:1004:zkapi:/:/bin/sh
agent:x:1005:1005:agent:/home/agent:/bin/sh
torport:x:1006:1006:torport:/:/bin/sh
sender:x:1007:1007:sender:/:/bin/sh
door:x:1008:1008:door:/:/bin/sh
PASSWD
cat > $root/etc/group <<GROUP
root:x:0:
adapter:x:1001:
checker:x:1002:
rewriter:x:1003:adapter,checker,zkapi
zkapi:x:1004:
agent:x:1005:
torport:x:1006:
sender:x:1007:
door:x:1008:
GROUP
chmod 0755 $root/run/cloak
chmod 1777 $root/tmp

(cd $root && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet) | gzip -n -9 > /out/initrd.gz

{
	dpkg-query -W linux-image-$kernel busybox-static bash bubblewrap torsocks ca-certificates libc6 libstdc++6 libgcc-s1 libcap2 libselinux1 libpcre2-8-0 libtinfo6
	# curl and the libraries only it loads: 21.2 MB of the root, 8.4 MB of initrd.gz (14 November 2026).
	dpkg-query -W curl libcurl4t64 libssl3t64 libgnutls30t64 libunistring5 libp11-kit0 libkrb5-3 libzstd1 libgmp10 \
		libgssapi-krb5-2 libldap2 libssh2-1t64 libhogweed6t64 libnettle8t64 libnghttp3-9 libnghttp2-14 libk5crypto3 \
		libidn2-0 libbrotli1 librtmp1 libsasl2-2 libtasn1-6 libpsl5t64 zlib1g libffi8 libkrb5support0 libcom-err2 libkeyutils1
	(cd /node && sha256sum node-v24.22.2-linux-arm64.tar.xz)
	(cd /pi && sha256sum earendil-works-pi-coding-agent-1.3.0.tgz)
	cd /out && sha256sum Image initrd.gz cloak-adapter cloak-port cloak-rewrite-check cloak-daemon cloak-agent-check \
		cloak-runner cloak-routing-probe cloak-vsock-probe cloak-sender
} > /out/guest-manifest.txt
cat /out/guest-manifest.txt
