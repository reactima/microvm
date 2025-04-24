#!/usr/bin/env bash
# install.sh – host-side one-shot setup
set -euo pipefail

echo "🔧  Step 1: prerequisites"
sudo apt update
sudo apt install -y --no-install-recommends \
     build-essential curl unzip git ca-certificates gnupg lsb-release \
     pkg-config libseccomp-dev libglib2.0-dev

echo "🐹  Step 2: Go toolchain"
if ! command -v go >/dev/null; then
  GO_VER=1.22.2
  GO_TAR=go${GO_VER}.linux-amd64.tar.gz
  curl -fsSL "https://go.dev/dl/$GO_TAR" -o /tmp/$GO_TAR
  sudo tar -C /usr/local -xzf /tmp/$GO_TAR
  rm /tmp/$GO_TAR
  echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
  export PATH=$PATH:/usr/local/go/bin
fi

echo "🧠  Step 3: /dev/kvm check"
[ -e /dev/kvm ] || { echo "❌  /dev/kvm missing"; exit 1; }

echo "🔥  Step 4: build Firecracker"
SRC=/tmp/firecracker-src
sudo rm -rf "$SRC"
git clone --depth 1 https://github.com/firecracker-microvm/firecracker.git "$SRC"
cd "$SRC"
tools/devtool build --release -- --features vsock,logger,metrics
sudo install -m 755 build/cargo_target/*/release/firecracker /usr/local/bin
cd -

echo "📦  Step 5: fetch demo kernel"
curl -# -Lo hello-vmlinux.bin \
     https://s3.amazonaws.com/spec.ccfc.min/img/hello/kernel/hello-vmlinux.bin

echo "✅  All set — run: make"
