#!/usr/bin/env bash
set -euo pipefail

echo "🔧  [1/13] Vars …"
IMG=alpine-rootfs.ext4
SIZE=128M
MNT=$(mktemp -d)
URL=https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz
TAR=/tmp/minirootfs.tar.gz

echo "🌐  [2/13] Download Alpine base …"
curl -#L "$URL" -o "$TAR"

echo "🗄   [3/13] Create ext4 image ($SIZE) …"
dd if=/dev/zero of="$IMG" bs="$SIZE" count=1
mkfs.ext4 -q "$IMG"

echo "📂  [4/13] Mount → $MNT …"
sudo mount -o loop "$IMG" "$MNT"

echo "📦  [5/13] Extract minirootfs …"
sudo tar -xzf "$TAR" -C "$MNT"

echo "🌍  [6/13] Copy DNS …"
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

echo "🔧  [7/13] Chroot: configure repos, install OpenRC + Dropbear …"
sudo chroot "$MNT" /bin/sh -e <<'EOF'
set -e
echo "https://dl-cdn.alpinelinux.org/alpine/v3.19/main"      >  /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/v3.19/community" >> /etc/apk/repositories

for n in 1 2 3; do
    echo "apk attempt $n …"
    if apk update && apk add --no-cache openrc busybox-initscripts dropbear; then
        echo "apk succeeded ✅"
        break
    fi
    if [ "$n" -eq 3 ]; then
        echo "❌ apk failed after 3 attempts" ; exit 1
    fi
    echo "retrying in 2 s …" ; sleep 2
done

echo 'root:firecracker' | chpasswd

rc-update add devfs      sysinit
rc-update add procfs     sysinit
rc-update add sysfs      sysinit
rc-update add networking default
rc-update add dropbear   default

cat > /etc/network/interfaces <<EONI
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet static
  address 172.16.0.2
  netmask 255.255.255.0
EONI

mkdir -p /run/openrc && touch /run/openrc/softlevel
exit
EOF

echo "⏏️  [8/13] Unmount …"
sudo umount "$MNT"
rm -rf "$MNT"

echo "🧹  [9/13] Remove tarball …"
rm -f "$TAR"

echo "🔐 [10/13] Root password : firecracker"
echo "✅ [11/13] $IMG created!"
