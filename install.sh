#!/usr/bin/env bash
# install.sh – host-side one-shot setup
set -euo pipefail

# Create the necessary directories under machines
mkdir -p machines/build/downloads
mkdir -p machines/build/firecracker

echo "🔧  Step 1: prerequisites"
sudo apt update
sudo apt install -y --no-install-recommends \
     build-essential curl unzip git ca-certificates gnupg lsb-release \
     pkg-config libseccomp-dev libglib2.0-dev

echo "📦 Step 2: Install Docker from official repo (avoid containerd conflict)"
if ! command -v docker &> /dev/null; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io
fi

echo "🚀 Step 3: Enable & start Docker"
sudo systemctl enable --now docker

echo "👥 Step 4: Add you to docker group"
sudo usermod -aG docker $USER

echo "🐹  Step 5: Go toolchain"
if ! command -v go >/dev/null; then
  GO_VER=1.22.2
  GO_TAR=go${GO_VER}.linux-amd64.tar.gz
  curl -fsSL "https://go.dev/dl/$GO_TAR" -o "machines/build/downloads/$GO_TAR"
  sudo tar -C /usr/local -xzf "machines/build/downloads/$GO_TAR"
  rm "machines/build/downloads/$GO_TAR"
  echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
  export PATH=$PATH:/usr/local/go/bin
fi

echo "🧠 Step 6: Check for /dev/kvm (required by Firecracker)"
if [ ! -e /dev/kvm ]; then
  echo "❌ /dev/kvm is missing. Firecracker requires KVM to run microVMs."
  echo "💡 Tip: Use a bare-metal Linux host or launch a Multipass/VM with --mount /dev/kvm:/dev/kvm"
  exit 1
fi

echo "🔥 Step 7: Clone & build Firecracker with log + metrics support"
SRC_DIR="machines/build/firecracker/firecracker-src"
sudo rm -rf "${SRC_DIR}"
git clone https://github.com/firecracker-microvm/firecracker.git "${SRC_DIR}"
cd "${SRC_DIR}"

# Enable logging, metrics, vsock
sg docker -c 'tools/devtool build -- --no-default-features --features vsock,logger,metrics'

echo "📁 Step 8: Locate the just-built binary and install atomically"
BIN_PATH=$(find build/cargo_target -type f -name firecracker -path '*/debug/firecracker' | head -n1)
if [ -z "$BIN_PATH" ]; then
  echo "❌ could not find built firecracker binary"
  exit 1
fi

# Copy to temp file then rename to avoid \"Text file busy\" errors
TMP_BIN="/usr/local/bin/firecracker.new"
sudo cp "$BIN_PATH" "$TMP_BIN"
sudo chmod 755 "$TMP_BIN"
sudo mv "$TMP_BIN" /usr/local/bin/firecracker

echo "📦  Step 9: fetch demo kernel"
curl -# -Lo "machines/build/downloads/hello-vmlinux.bin" \
     https://s3.amazonaws.com/spec.ccfc.min/img/hello/kernel/hello-vmlinux.bin

echo "✅  All set "
