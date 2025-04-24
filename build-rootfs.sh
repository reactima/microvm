#!/usr/bin/env bash
set -euo pipefail

echo "🔧  [1/17] Vars"
IMG=alpine-rootfs.ext4
SIZE=64M
MNT=$(mktemp -d)
URL=https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz
TAR=/tmp/alpine-mini.tar.gz

echo "🌐  [2/17] Download mini rootfs"
curl -#L "$URL" -o "$TAR"

echo "🗄   [3/17] Create ext4 $SIZE"
dd if=/dev/zero of="$IMG" bs="$SIZE" count=1
mkfs.ext4 -q "$IMG"

echo "📂  [4/17] Mount → $MNT"
sudo mount -o loop "$IMG" "$MNT"

echo "📦  [5/17] Extract rootfs"
sudo tar -xzf "$TAR" -C "$MNT"

echo "🌍  [6/17] Copy host DNS"
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

echo "🔧  [7/17] Configure APK mirrors"
sudo sh -c "printf '%s\n%s\n' \
https://dl-cdn.alpinelinux.org/alpine/v3.19/main \
https://dl-cdn.alpinelinux.org/alpine/v3.19/community \
> $MNT/etc/apk/repositories"

echo "📦  [8/17] Chroot: install Dropbear"
sudo chroot "$MNT" /bin/sh -e <<'EOF'
for n in 1 2 3; do
  echo "apk attempt $n"
  apk update && apk add --no-cache dropbear && break
  [ "$n" -eq 3 ] && exit 1 || sleep 2
done
echo 'root:firecracker' | chpasswd
# busybox init script: bring up eth0 then start dropbear
cat > /etc/inittab <<EOT
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/sbin/ifconfig eth0 172.16.0.2 netmask 255.255.255.0 up
::respawn:/usr/sbin/dropbear -F -E
::askfirst:/bin/ash
::ctrlaltdel:/bin/umount -a -r
EOT
exit
EOF

echo "⏏️  [9/17] Unmount image"
sudo umount "$MNT"
rm -rf "$MNT"

echo "🚫  [10/17] Remove journal (faster boot)"
sudo tune2fs -O ^has_journal "$IMG"
sudo e2fsck -fy "$IMG" >/dev/null

echo "🧹  [11/17] Clean tar"
rm -f "$TAR"

echo "🔐  [12/17] root pwd : firecracker"
echo "✅  [13/17] $IMG ready"
