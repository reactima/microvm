#!/usr/bin/env bash
set -euo pipefail

############################################################
# Alpine + OpenRC + Dropbear rootfs builder
# Every step echoes its progress for easy debugging
############################################################

echo "🔧  [1/14] Init vars"
IMG=alpine-rootfs.ext4
SIZE=64M
MNT=$(mktemp -d)
URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz"
TAR=/tmp/alpine-mini.tar.gz

echo "🌐  [2/14] Download Alpine minirootfs"
curl -#L "$URL" -o "$TAR"

echo "🗄   [3/14] Create $SIZE ext4 image $IMG"
dd if=/dev/zero of="$IMG" bs="$SIZE" count=1
mkfs.ext4 -q "$IMG"

echo "📂  [4/14] Mount image → $MNT"
sudo mount -o loop "$IMG" "$MNT"

echo "📦  [5/14] Extract minirootfs into image"
sudo tar -xzf "$TAR" -C "$MNT"

echo "🌍  [6/14] Copy DNS resolver"
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

echo "🔧  [7/14] Configure APK repositories"
sudo sh -c "printf '%s\n%s\n' \
https://dl-cdn.alpinelinux.org/alpine/v3.19/main \
https://dl-cdn.alpinelinux.org/alpine/v3.19/community \
> $MNT/etc/apk/repositories"

echo "📦  [8/14] Chroot: install OpenRC & Dropbear (3-try retry)"
sudo chroot "$MNT" /bin/sh -e <<'EOF'
for n in 1 2 3; do
  echo "    → apk try $n"
  if apk update && apk add --no-cache openrc busybox-initscripts dropbear; then
      echo "    ✓ apk succeeded"; break
  fi
  [ "$n" -eq 3 ] && { echo "    ✗ apk failed after 3 tries"; exit 1; }
  echo "    … retrying in 2 s"; sleep 2
done
echo 'root:firecracker' | chpasswd
rc-update add devfs      sysinit
rc-update add procfs     sysinit
rc-update add sysfs      sysinit
rc-update add networking default
rc-update add dropbear   default
mkdir -p /run/openrc && touch /run/openrc/softlevel
cat > /etc/network/interfaces <<EONI
auto eth0
iface eth0 inet static
  address 172.16.0.2
  netmask 255.255.255.0
EONI
exit
EOF

echo "⏏️  [9/14] Unmount image"
sudo umount "$MNT"
rm -rf "$MNT"

echo "🧹  [10/14] Delete downloaded tarball"
rm -f "$TAR"

echo "🚫  [11/14] Strip ext4 journal (speed-up boot)"
sudo tune2fs -O ^has_journal "$IMG"

echo "🧽  [12/14] fsck & mark clean"
sudo e2fsck -fy "$IMG" >/dev/null

echo "🔐  [13/14] Root password  : firecracker"
echo "✅  [14/14] $IMG ready!"
