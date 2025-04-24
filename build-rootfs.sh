#!/usr/bin/env bash
set -euo pipefail

echo "🔧  [1/16] Vars"
IMG=alpine-rootfs.ext4
SIZE=64M
MNT=$(mktemp -d)
URL=https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz
TAR=/tmp/alpine-mini.tar.gz

echo "🌐  [2/16] Download minirootfs"
curl -#L "$URL" -o "$TAR"

echo "🗄   [3/16] Create ext4 $SIZE"
dd if=/dev/zero of="$IMG" bs="$SIZE" count=1
mkfs.ext4 -q "$IMG"

echo "📂  [4/16] Mount → $MNT"
sudo mount -o loop "$IMG" "$MNT"

echo "📦  [5/16] Extract"
sudo tar -xzf "$TAR" -C "$MNT"

echo "🌍  [6/16] DNS"
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

echo "🔧  [7/16] Configure repos"
sudo sh -c "printf '%s\n%s\n' \
https://dl-cdn.alpinelinux.org/alpine/v3.19/main \
https://dl-cdn.alpinelinux.org/alpine/v3.19/community \
> $MNT/etc/apk/repositories"

echo "📦  [8/16] Chroot: install Dropbear only"
sudo chroot "$MNT" /bin/sh -e <<'EOF'
for n in 1 2 3; do
  echo "apk try $n"; apk update && apk add --no-cache dropbear && break
  [ $n -eq 3 ] && exit 1 || sleep 2
done
echo 'root:firecracker' | chpasswd
mkdir -p /etc/dropbear
cat > /etc/inittab <<EOT
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::respawn:/usr/sbin/dropbear -F -E
::askfirst:/bin/ash
::ctrlaltdel:/bin/umount -a -r
EOT
exit
EOF

echo "⏏️  [9/16] Unmount"
sudo umount "$MNT"
rm -rf "$MNT"

echo "🚫  [10/16] Strip journal"
sudo tune2fs -O ^has_journal "$IMG"

echo "🧽  [11/16] fsck"
sudo e2fsck -fy "$IMG" >/dev/null

echo "🧹  [12/16] Cleanup tar"
rm -f "$TAR"

echo "🔐  [13/16] root pwd : firecracker"
echo "✅  [14/16] $IMG ready"
