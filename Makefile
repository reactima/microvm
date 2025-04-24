# Makefile – clean, idempotent, sudo-safe
# ======================================

# ─── paths ─────────────────────────────────────────────────────────────
FC_BIN      := /usr/local/bin/firecracker
KERNEL_IMG  := hello-vmlinux.bin
ROOTFS_IMG  := alpine-rootfs.ext4
BUILD_SH    := $(CURDIR)/build-rootfs.sh

MACH        := machine
API_SOCK    := $(MACH)/fc.sock
LOG_FILE    := $(MACH)/fc.log
METRICS     := $(MACH)/fc.metrics
BOOT_JSON   := $(MACH)/boot.json
DRIVE_JSON  := $(MACH)/drive.json
NET_JSON    := $(MACH)/net.json

TAP   := tap0
MAC   := AA:FC:00:00:00:01
HOST  := 172.16.0.1
GUEST := 172.16.0.2
MASK  := 255.255.255.0

.PHONY: all rootfs setup net run ssh clean

# ─── high-level targets ────────────────────────────────────────────────
all: rootfs setup net run

# rootfs – build image once (works under sudo or unprivileged)
rootfs:
	@if [ ! -f $(ROOTFS_IMG) ]; then \
	    echo "📦  building rootfs…"; \
	    if [ $$(id -u) -eq 0 ]; then $(BUILD_SH); \
	    else sudo $(BUILD_SH); fi; \
	fi

# setup – generate Firecracker config JSONs
setup:
	@mkdir -p $(MACH); touch $(LOG_FILE) $(METRICS)
	@printf '{\n "kernel_image_path":"%s",\n "boot_args":"console=ttyS0 reboot=k panic=1 pci=off virtio_mmio.device=4K@0xd0000000:5 root=/dev/vda rw ip=%s::%s:%s::eth0:off quiet init=/sbin/init"\n}\n' \
	    "$(abspath $(KERNEL_IMG))" $(GUEST) $(HOST) $(MASK) > $(BOOT_JSON)
	@printf '{\n "drive_id":"rootfs",\n "path_on_host":"%s",\n "is_root_device":true,\n "is_read_only":false\n}\n' \
	    "$(abspath $(ROOTFS_IMG))" > $(DRIVE_JSON)
	@printf '{\n "iface_id":"eth0",\n "host_dev_name":"%s",\n "guest_mac":"%s"\n}\n' \
	    $(TAP) $(MAC) > $(NET_JSON)

# net – ensure tun module + tap0
net:
	@sudo modprobe -q tun || true
	@if ip link show $(TAP) &>/dev/null; then \
	  echo "♻️  reuse $(TAP)"; \
	  sudo ip link set $(TAP) up; \
	else \
	  echo "🔌  create $(TAP)"; \
	  if ! sudo ip tuntap add dev $(TAP) mode tap user $$(id -un) 2>/dev/null; then \
	    echo "   ↳ fallback (root-owned tap)"; \
	    sudo ip tuntap add dev $(TAP) mode tap; \
	  fi; \
	  sudo ip addr add $(HOST)/24 dev $(TAP); \
	  sudo ip link set $(TAP) up; \
	fi
	@sudo sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
	@sudo iptables -C POSTROUTING -t nat -s $(GUEST)/32 -j MASQUERADE 2>/dev/null || \
	  sudo iptables -A POSTROUTING -t nat -s $(GUEST)/32 -j MASQUERADE
# ───────────────────────────────────────────────────────────────────────

# run – start Firecracker
run:
	@rm -f $(API_SOCK)
	$(FC_BIN) --api-sock $(API_SOCK) --log-path $(LOG_FILE) --metrics-path $(METRICS) & \
	FC=$$!; while [ ! -S $(API_SOCK) ]; do sleep .1; done; \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H'Content-Type: application/json' -d@$(BOOT_JSON)  http://localhost/boot-source ; \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H'Content-Type: application/json' -d@$(DRIVE_JSON) http://localhost/drives/rootfs ; \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H'Content-Type: application/json' -d@$(NET_JSON)   http://localhost/network-interfaces/eth0 ; \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H'Content-Type: application/json' -d'{"action_type":"InstanceStart"}' http://localhost/actions ; \
	echo "✅  microVM up — run 'make ssh'"; \
	wait $$FC

# ssh – log in
ssh: ; ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$(GUEST)

# clean – full teardown
clean:
	-pkill -x firecracker 2>/dev/null || true
	-sudo ip link del $(TAP) 2>/dev/null || true
	-rm -rf $(MACH) $(ROOTFS_IMG)
