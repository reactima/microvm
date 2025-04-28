# ---------------------------------------------------------------------------
# Firecracker micro-VM playground
# ---------------------------------------------------------------------------
# 1.  make            – classic single-VM workflow (tap0 → 172.16.0.2)
# 2.  make run-go     – spin up 3 VMs (172.16.0.10/11/12) via main.go
# 3.  make ssh        – SSH into default VM   (172.16.0.2)
#     make ssh VM=11  – SSH into multi-VM #11 (172.16.0.11)
# ---------------------------------------------------------------------------

# Base directory for machines build
MACHINES_DIR := machines
BUILD_DIR := $(MACHINES_DIR)/build
DOWNLOADS_DIR := $(BUILD_DIR)/downloads

# Firecracker binary and kernel image
FC_BIN      := /usr/local/bin/firecracker
KERNEL_IMG  := $(DOWNLOADS_DIR)/hello-vmlinux.bin
ROOTFS_IMG  := $(BUILD_DIR)/alpine-rootfs.ext4
BUILD_SH    := $(CURDIR)/build-rootfs.sh

# single-VM artefacts --------------------------------------------------------
MACH        := $(MACHINES_DIR)/machine
API_SOCK    := $(MACH)/fc.sock
LOG_FILE    := $(MACH)/fc.log
METRICS     := $(MACH)/fc.metrics
BOOT_JSON   := $(MACH)/boot.json
DRIVE_JSON  := $(MACH)/drive.json
NET_JSON    := $(MACH)/net.json

# single-VM network ---------------------------------------------------------
TAP         := tap0
MAC         := AA:FC:00:00:00:01
HOST        := 172.16.0.1
GUEST       := 172.16.0.2

# ssh defaults --------------------------------------------------------------
GUEST_DEFAULT := $(GUEST)
SSH_USER      := root
SSH_OPTS      := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
define vm_ip
$(if $(VM),172.16.0.$(VM),$(GUEST_DEFAULT))
endef

# targets --------------------------------------------------------------------
.PHONY: all rootfs kernel setup net run ssh clean metrics run-go git-reset

all: rootfs setup net run

rootfs:
	@if [ ! -f $(ROOTFS_IMG) ]; then sudo $(BUILD_SH); fi

setup:
	@mkdir -p $(MACH); touch $(LOG_FILE) $(METRICS)
	@printf '{\n "kernel_image_path":"%s",\n "boot_args":"console=ttyS0 reboot=k panic=1 pci=off virtio_mmio.device=4K@0xd0000000:5 root=/dev/vda rw quiet"}\n' \
	    "$(abspath $(KERNEL_IMG))" > $(BOOT_JSON)
	@printf '{\n "drive_id":"rootfs","path_on_host":"%s","is_root_device":true,"is_read_only":false}\n' \
	    "$(abspath $(ROOTFS_IMG))" > $(DRIVE_JSON)
	@printf '{\n "iface_id":"eth0","host_dev_name":"%s","guest_mac":"%s"}\n' \
	    $(TAP) $(MAC) > $(NET_JSON)

net:
	@sudo modprobe tun
	@sudo ip link del $(TAP) 2>/dev/null || true
	@sudo ip tuntap add dev $(TAP) mode tap
	@sudo ip addr add $(HOST)/24 dev $(TAP)
	@sudo ip link set $(TAP) up
	@sudo sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
	@sudo iptables -C POSTROUTING -t nat -s $(GUEST)/32 -j MASQUERADE 2>/dev/null || \
	  sudo iptables -A POSTROUTING -t nat -s $(GUEST)/32 -j MASQUERADE

run:
	@rm -f $(API_SOCK)
	$(FC_BIN) --api-sock $(API_SOCK) --log-path $(LOG_FILE) --metrics-path $(METRICS) & \
	FC=$$!; while [ ! -S $(API_SOCK) ]; do sleep .1; done; \
	curl --unix-socket $(API_SOCK) -sS -X PUT -H 'Content-Type: application/json' -d@$(BOOT_JSON)  http://localhost/boot-source ; \
	curl --unix-socket $(API_SOCK) -sS -X PUT -H 'Content-Type: application/json' -d@$(DRIVE_JSON) http://localhost/drives/rootfs ; \
	curl --unix-socket $(API_SOCK) -sS -X PUT -H 'Content-Type: application/json' -d@$(NET_JSON)   http://localhost/network-interfaces/eth0 ; \
	curl --unix-socket $(API_SOCK) -sS -X PUT -H 'Content-Type: application/json' -d '{"action_type":"InstanceStart"}' http://localhost/actions ; \
	echo "single VM ready — make ssh"; \
	wait $$FC

ssh:
	@echo "→ SSH to $(call vm_ip)"
	@ssh $(SSH_OPTS) $(SSH_USER)@$(call vm_ip)

clean:
	-pkill -x firecracker 2>/dev/null || true
	-sudo ip link del $(TAP) 2>/dev/null || true
	-rm -rf $(MACHINES_DIR)/machine $(ROOTFS_IMG) $(MACHINES_DIR)/vm*

metrics:
	@curl --unix-socket $(API_SOCK) -sS http://localhost/metrics | jq .

run-go:            ## multi-VM launcher (needs root)
	@sudo ip addr del $(HOST)/24 dev $(TAP) 2>/dev/null || true
	@sudo -E $(shell which go) run main.go

git-reset: ## git-reset
	cd /ilya/microvm
	git reset --hard HEAD
	git pull origin main
