#!/usr/bin/env bash
set -euo pipefail

IMG=alpine-rootfs.ext4   # final image name
SIZE=128M                # grow later if you need more
MNT=/mnt/alpine-fc

# 1. download tiny Alpine base
[ -f minirootfs.tar.gz ] || \
  curl -# -o minirootfs.tar.gz \
  https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz

# 2. create blank ext4 image
dd if=/dev/zero of=$IMG bs=$SIZE count=1
mkfs.ext4 -q $IMG

# 3. populate it
sudo mkdir -p $MNT
sudo mount -o loop $IMG $MNT
sudo tar -xzf minirootfs.tar.gz -C $MNT

# 4. chroot & set up dropbear + networking
sudo chroot $MNT /bin/sh -e <<'EOF'
apk add --no-cache dropbear openssh-keygen
echo 'root:firecracker' | chpasswd
rc-update add networking default
rc-update add dropbear default
echo "auto lo"        >  /etc/network/interfaces
echo "iface lo inet loopback" >> /etc/network/interfaces
echo "auto eth0"      >> /etc/network/interfaces
echo "iface eth0 inet static" >> /etc/network/interfaces
echo "  address 172.16.0.2"   >> /etc/network/interfaces
echo "  netmask 255.255.255.0" >> /etc/network/interfaces
exit
EOF

sudo umount $MNT
echo "✅ $IMG ready (root password: firecracker)"
