#!/usr/bin/env bash
set -e

echo "🔧 Step 1: Update & install prerequisites"
sudo apt update
sudo apt install -y pkg-config libseccomp-dev libglib2.0-dev curl unzip git build-essential ca-certificates gnupg lsb-release

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

echo "🐹 Step 5: Install Go if missing"
if ! command -v go &> /dev/null; then
  GO_TARBALL=go1.21.5.linux-amd64.tar.gz
  curl -fsSL https://go.dev/dl/${GO_TARBALL} -o /tmp/${GO_TARBALL}
  sudo tar -C /usr/local -xzf /tmp/${GO_TARBALL}
  rm /tmp/${GO_TARBALL}
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
SRC_DIR=/tmp/firecracker-src
sudo rm -rf "${SRC_DIR}"
git clone https://github.com/firecracker-microvm/firecracker.git "${SRC_DIR}"
cd "${SRC_DIR}"

# Enable logging, metrics, vsock
sg docker -c 'tools/devtool build -- --no-default-features --features vsock,logger,metrics'

echo "📁 Step 8: Locate the just-built binary and install"
BIN_PATH=$(find build/cargo_target -type f -name firecracker -path '*/debug/firecracker' | head -n1)
if [ -z "$BIN_PATH" ]; then
  echo "❌ could not find built firecracker binary"
  exit 1
fi
sudo cp "$BIN_PATH" /usr/local/bin/firecracker

echo "📦 Step 9: Download kernel & rootfs into current project"
cd "$OLDPWD"
curl -# -o hello-vmlinux.bin https://s3.amazonaws.com/spec.ccfc.min/img/hello/kernel/hello-vmlinux.bin
curl -# -o hello-rootfs.ext4 https://s3.amazonaws.com/spec.ccfc.min/img/hello/fsfiles/hello-rootfs.ext4


echo "✅ Firecracker with logger+metrics support built and installed"
echo "💡 Run from this directory: make clean && make setup && make run"
