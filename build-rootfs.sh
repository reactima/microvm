#!/usr/bin/env bash
set -euo pipefail

echo "🔧  [1/9] Preparing vars …"
IMG=alpine-rootfs.ext4
SIZE=128M
MNT=$(mktemp -d)
URL=https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz

echo "🌐  [2/9] Downloading Alpine minirootfs …"
curl -#L "$URL" -o /tmp/minirootfs.tar.gz

echo "🗄   [3/9] Creating blank ext4 image ($SIZE) …"
dd if=/dev/zero of="$IMG" bs="$SIZE" count=1
mkfs.ext4 -q "$IMG"

echo "📂  [4/9] Mounting image to $MNT …"
sudo mount -o loop "$IMG" "$MNT"

echo "📦  [5/9] Extracting rootfs …"
sudo tar -xzf /tmp/minirootfs.tar.gz -C "$MNT"

echo "🔧  [6/9] Chroot: install Dropbear and config network …"
sudo chroot "$MNT" /bin/sh -e <<'EOF'
apk add --no-cache dropbear
echo 'root:firecracker' | chpasswd
rc-update add networking default
rc-update add dropbear default
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

echo "⏏️  [7/9] Unmounting image …"
sudo umount "$MNT"
rm -rf "$MNT"

echo "🧹  [8/9] Cleaning up tarball …"
rm -f /tmp/minirootfs.tar.gz

echo "✅  [9/9] $IMG ready (root password: firecracker)"
