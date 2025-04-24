# install.sh
#!/usr/bin/env bash
set -e

echo "🔧 Step 1: install prerequisites"
sudo apt update
sudo apt install -y pkg-config libseccomp-dev libglib2.0-dev curl unzip git build-essential ca-certificates gnupg lsb-release

echo "🐹 Step 2: install Go (if missing)"
if ! command -v go >/dev/null; then
  GO_TAR=go1.21.5.linux-amd64.tar.gz
  curl -fsSL https://go.dev/dl/$GO_TAR -o /tmp/$GO_TAR
  sudo tar -C /usr/local -xzf /tmp/$GO_TAR
  rm /tmp/$GO_TAR
  echo 'export PATH=$$PATH:/usr/local/go/bin' >> ~/.bashrc
  export PATH=$PATH:/usr/local/go/bin
fi

echo "🧠 Step 3: verify /dev/kvm"
[ -e /dev/kvm ] || { echo "❌ /dev/kvm missing"; exit 1; }

echo "🔥 Step 4: build Firecracker"
SRC=/tmp/firecracker-src
sudo rm -rf $SRC
git clone --depth 1 https://github.com/firecracker-microvm/firecracker.git $SRC
cd $SRC
tools/devtool build --release -- --features vsock,logger,metrics
sudo cp build/cargo_target/x86_64-unknown-linux-gnu/release/firecracker /usr/local/bin/firecracker
cd -

echo "📦 Step 5: download demo kernel"
curl -# -o hello-vmlinux.bin https://s3.amazonaws.com/spec.ccfc.min/img/hello/kernel/hello-vmlinux.bin
echo "✅ install done. run: make"
