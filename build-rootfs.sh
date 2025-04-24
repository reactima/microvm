#!/usr/bin/env bash
# build-rootfs.sh – Alpine 3.19 + Python + haveged + Dropbear (auto-login)

set -euo pipefail

IMG=alpine-rootfs.ext4
SIZE=512M
MNT=$(mktemp -d)
URL=https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.2-x86_64.tar.gz
TAR=/tmp/alpine-mini.tar.gz

cleanup(){ sudo umount "$MNT" 2>/dev/null || true; rm -rf "$MNT"; }
trap cleanup EXIT

echo "🌐  Download Alpine minirootfs"
curl -#L "$URL" -o "$TAR"

echo "🗄   Create ext4 $SIZE"
dd if=/dev/zero of="$IMG" bs="$SIZE" count=1
mkfs.ext4 -q "$IMG"

echo "📂  Mount → $MNT"
sudo mount -o loop "$IMG" "$MNT"

echo "📦  Extract rootfs"
sudo tar -xzf "$TAR" -C "$MNT"

echo "🌍  Copy DNS"
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

echo "🔧  Configure APK mirrors"
sudo tee "$MNT/etc/apk/repositories" >/dev/null <<EOF
https://dl-cdn.alpinelinux.org/alpine/v3.19/main
https://dl-cdn.alpinelinux.org/alpine/v3.19/community
EOF

echo "📦  Chroot: install Python, Dropbear, haveged, build tools"
sudo chroot "$MNT" /bin/sh -e <<'EOS'
apk update
apk add --no-cache \
  python3 py3-pip \
  dropbear busybox-extras haveged \
  build-base python3-dev musl-dev

ln -sf python3 /usr/bin/python
echo 'root:firecracker' | chpasswd
ln -sf /bin/busybox /sbin/ifconfig

# SSH keys for Dropbear
for t in rsa dss ecdsa ed25519; do
  dropbearkey -t $t -f /etc/dropbear/dropbear_${t}_host_key >/dev/null
done

# Init setup
cat > /etc/inittab <<'EOT'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -t devtmpfs devtmpfs /dev
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/sbin/ifconfig eth0 172.16.0.2 netmask 255.255.255.0 up
::respawn:/usr/sbin/haveged -F -w 1024
::respawn:/usr/sbin/dropbear -F -E
::respawn:/bin/ash
::ctrlaltdel:/bin/umount -a -r
EOT
exit
EOS

echo "⏏️   Unmount"
sudo umount "$MNT"

echo "🚫  Strip journal"
sudo tune2fs -O ^has_journal "$IMG"
sudo e2fsck -fy "$IMG" >/dev/null

echo "🧹  Clean"
rm -f "$TAR"

echo "🔐  root pwd : firecracker"
echo "✅  $IMG ready"
