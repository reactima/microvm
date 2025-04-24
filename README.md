# Firecracker MicroVM Launcher for Data Analytics

This project demonstrates spinning up thousands of Firecracker MicroVMs with sub-second boot times, each ready with a minimal environment suitable for lightweight data analytics—similar in spirit to [lovable.dev](https://lovable.dev). It includes:

- A `Makefile` to automate Firecracker VM setup and launch
- A Go program to manage and launch VMs using the Firecracker Go SDK
- A setup script to prepare your Linux environment and build Firecracker with logging and metrics support

## 🚀 Goals

- Launch microVMs in under 1 second
- Provide ephemeral environments on demand
- Enable scalable, secure, isolated compute for analytics workloads

## 🧰 Requirements

- Ubuntu Linux (bare-metal or KVM-enabled VM)
- `/dev/kvm` available and accessible
- `bash`, `make`, `curl`, `docker`, `go`, etc.

## 🔧 Setup

To install prerequisites, build Firecracker, and download kernel/rootfs:

```bash
./install.sh
```

This script does the following:
- Installs Docker and Go if not present
- Adds current user to the Docker group
- Clones and builds Firecracker with `logger`, `metrics`, and `vsock` support
- Downloads minimal kernel and rootfs for the demo VM

> Note: Ensure your host has `/dev/kvm` enabled.

## 📦 Files Overview

- `Makefile` – automates VM setup, launch, and teardown
- `main.go` – starts and stops a VM using Firecracker Go SDK
- `setup.sh` – installs tools, builds Firecracker, downloads demo kernel & rootfs
- `hello-vmlinux.bin` – demo kernel image
- `hello-rootfs.ext4` – demo root filesystem
- `machine/` – runtime data like socket, logs, and VM JSON config files

## ▶️ Running the VM

From the root directory, run:

```bash
make clean && make setup && make run
```

This:
- Prepares a `machine/` directory with boot and rootfs config
- Starts Firecracker via the `fc.sock` API socket
- Configures the VM and launches it into a shell (`init=/bin/sh`)


## 📚 References

- [Firecracker GitHub](https://github.com/firecracker-microvm/firecracker)
- [Firecracker Go SDK](https://github.com/firecracker-microvm/firecracker-go-sdk)
- [lovable.dev](https://lovable.dev) for ephemeral environments inspiration

## 💡 Future Plans

- Launch multiple concurrent VMs with custom workloads
- Mount volumes and pass envs for per-job analytics
- Integrate with container registries or blob storage