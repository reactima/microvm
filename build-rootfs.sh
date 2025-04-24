#!/usr/bin/env bash
set -euo pipefail

echo "🔧  [1/12] Vars ..."
IMG=alpine-rootfs.ext4
SIZE=128M
MNT=$(mktemp -d)
URL=https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz
TAR=/tmp/minirootfs.tar.gz

echo "🌐  [2/12] Download Alpine base ..."
curl -#L "$URL" -o "$TAR"

echo "🗄   [3/12] Create ext4 image $SIZE ..."
dd if=/dev/zero of="$IMG" bs="$SIZE" count=1
mkfs.ext4 -q "$IMG"

echo "📂  [4/12] Mount -> $MNT ..."
sudo mount -o loop "$IMG" "$MNT"

echo "📦  [5/12] Extract minirootfs ..."
sudo tar -xzf "$TAR" -C "$MNT"

echo "🌍  [6/12] Copy DNS ..."
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

echo "🔧  [7/12] Chroot: add openrc + dropbear ..."
sudo chroot "$MNT" /bin/sh -e <<'EOF'
set -e
apk update
apk add --no-cache openrc busybox-initscripts dropbear
echo 'root:firecracker' | chpasswd
rc-update add devfs     sysinit
rc-update add procfs    sysinit
rc-update add sysfs     sysinit
rc-update add networking default
rc-update add dropbear  default
# basic network
cat > /etc/network/interfaces <<EONI
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
  address 172.16.0.2
  netmask 255.255.255.0
EONI
# OpenRC inside containers needs this:
mkdir -p /run/openrc && touch /run/openrc/softlevel
exit
EOF

echo "⏏️  [8/12] Unmount ..."
sudo umount "$MNT"
rm -rf "$MNT"

echo "🧹  [9/12] Remove tarball"
rm -f "$TAR"

echo "✅  [10/12] $IMG ready (root pwd: firecracker)"
