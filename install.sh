#!/usr/bin/env bash
set -e

echo "Step 1: Update & install prerequisites"
sudo apt update
sudo apt install -y pkg-config libseccomp-dev libglib2.0-dev curl unzip git build-essential docker.io

echo "Step 2: Enable & start Docker"
sudo systemctl enable --now docker

echo "Step 3: Add you to docker group"
sudo usermod -aG docker $USER

echo "Step 4: Install Go if missing"
if ! command -v go &> /dev/null; then
  GO_TARBALL=go1.21.5.linux-amd64.tar.gz
  curl -fsSL https://go.dev/dl/${GO_TARBALL} -o /tmp/${GO_TARBALL}
  sudo tar -C /usr/local -xzf /tmp/${GO_TARBALL}
  rm /tmp/${GO_TARBALL}
  echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
  export PATH=$PATH:/usr/local/go/bin
fi

echo "Step 5: Clone & build Firecracker with log + metrics support"
SRC_DIR=/tmp/firecracker-src
sudo rm -rf "${SRC_DIR}"
git clone https://github.com/firecracker-microvm/firecracker.git "${SRC_DIR}"
cd "${SRC_DIR}"

# Enable logging, metrics, vsock
sg docker -c 'tools/devtool build -- --features vsock,logger,metrics'

echo "Step 6: Locate the just-built binary and install"
BIN_PATH=$(find build/cargo_target -type f -name firecracker -path '*/debug/firecracker' | head -n1)
if [ -z "$BIN_PATH" ]; then
  echo "❌ could not find built firecracker binary"
  exit 1
fi
sudo cp "$BIN_PATH" /usr/local/bin/firecracker

echo "Step 7: Download kernel & rootfs"
WORKDIR=~/fc-demo
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
[ -f vmlinux.bin ] || curl -Lo vmlinux.bin https://s3.amazonaws.com/spec.ccfc.min/clear/31390/vmlinux.bin
[ -f rootfs.ext4 ]   || curl -Lo rootfs.ext4   https://s3.amazonaws.com/spec.ccfc.min/clear/31390/rootfs.ext4

echo "✔️ Firecracker with logger+metrics support built and installed"
echo "📂 Project directory: ${WORKDIR}"
