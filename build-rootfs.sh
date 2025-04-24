#!/usr/bin/env bash
set -euo pipefail

echo "🔧  [1/11] Preparing vars …"
IMG=alpine-rootfs.ext4
SIZE=128M
MNT=$(mktemp -d)
URL=https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz
TAR=/tmp/minirootfs.tar.gz

echo "🌐  [2/11] Downloading Alpine minirootfs …"
curl -#L "$URL" -o "$TAR"

echo "🗄   [3/11] Creating blank ext4 image ($SIZE) …"
dd if=/dev/zero of="$IMG" bs="$SIZE" count=1
mkfs.ext4 -q "$IMG"

echo "📂  [4/11] Mounting image to $MNT …"
sudo mount -o loop "$IMG" "$MNT"

echo "📦  [5/11] Extracting rootfs …"
sudo tar -xzf "$TAR" -C "$MNT"

echo "🌍  [6/11] Copying host DNS into new rootfs …"
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

echo "🔧  [7/11] Chroot: install Dropbear & configure network …"
sudo chroot "$MNT" /bin/sh -e <<'EOF'
set -e
apk update
# first try
if ! apk add --no-cache dropbear; then
    echo "⚠️  apk failed, retrying once …"
    apk update
    apk add --no-cache dropbear
fi
echo 'root:firecracker' | chpasswd
rc-update add networking  default
rc-update add dropbear    default
cat > /etc/network/interfaces <<EONI
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet static
  address 172.16.0.2
  netmask 255.255.255.0
EONI
exit
EOF

echo "⏏️  [8/11] Unmounting image …"
sudo umount "$MNT"
rm -rf "$MNT"

echo "🧹  [9/11] Removing tarball …"
rm -f "$TAR"

echo "🔐 [10/11] Root password  : firecracker"
echo "📁 [11/11] $IMG created!"
