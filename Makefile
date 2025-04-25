# Makefile – rebuild tap0 each run, entropy via haveged, no /entropy API

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
all: rootfs setup net run

rootfs:
	@if [ ! -f $(ROOTFS_IMG) ]; then \
	    echo "📦  building rootfs…"; \
	    ( [ $$(id -u) -eq 0 ] && $(BUILD_SH) || sudo $(BUILD_SH) ); \
	fi

setup-old:
	@mkdir -p $(MACH); touch $(LOG_FILE) $(METRICS)
	@printf '{\n "kernel_image_path":"%s",\n "boot_args":"console=ttyS0 reboot=k panic=1 pci=off random.trust_cpu=on virtio_mmio.device=4K@0xd0000000:5 root=/dev/vda rw ip=%s::%s:%s::eth0:off quiet init=/bin/ash"\n}\n' \
	    "$(abspath $(KERNEL_IMG))" $(GUEST) $(HOST) $(MASK) > $(BOOT_JSON)
	@printf '{\n "drive_id":"rootfs",\n "path_on_host":"%s",\n "is_root_device":true,\n "is_read_only":false\n}\n' \
	    "$(abspath $(ROOTFS_IMG))" > $(DRIVE_JSON)
	@printf '{\n "iface_id":"eth0",\n "host_dev_name":"%s",\n "guest_mac":"%s"\n}\n' \
	    $(TAP) $(MAC) > $(NET_JSON)

setup:
	@mkdir -p $(MACH); touch $(LOG_FILE) $(METRICS)
	# REMOVED: ip=$(GUEST)::$(HOST):$(MASK)::eth0:off quiet init=/bin/ash
	# ADDED:   quiet (retained quiet, removed ip= and init=)
	@printf '{\n "kernel_image_path":"%s",\n "boot_args":"console=ttyS0 reboot=k panic=1 pci=off random.trust_cpu=on virtio_mmio.device=4K@0xd0000000:5 root=/dev/vda rw quiet"\n}\n' \
	    "$(abspath $(KERNEL_IMG))" > $(BOOT_JSON)
	@printf '{\n "drive_id":"rootfs",\n "path_on_host":"%s",\n "is_root_device":true,\n "is_read_only":false\n}\n' \
	    "$(abspath $(ROOTFS_IMG))" > $(DRIVE_JSON)
	@printf '{\n "iface_id":"eth0",\n "host_dev_name":"%s",\n "guest_mac":"%s"\n}\n' \
	    $(TAP) $(MAC) > $(NET_JSON)

net:
	@sudo modprobe -q tun || true
	@echo "🔌  recreate $(TAP)"
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
	curl -sS --unix-socket $(API_SOCK) -X PUT -H 'Content-Type: application/json' -d@$(BOOT_JSON)  http://localhost/boot-source ; \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H 'Content-Type: application/json' -d@$(DRIVE_JSON) http://localhost/drives/rootfs ; \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H 'Content-Type: application/json' -d@$(NET_JSON)   http://localhost/network-interfaces/eth0 ; \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H 'Content-Type: application/json' \
	     -d '{"action_type":"InstanceStart"}' http://localhost/actions ; \
	echo "✅  microVM up — run 'make ssh'"; \
	wait $$FC


ssh:
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$(GUEST)

clean:
	-pkill -x firecracker 2>/dev/null || true
	-sudo ip link del $(TAP) 2>/dev/null || true
	-rm -rf $(MACH) $(ROOTFS_IMG)

metrics:
	@curl -sS --unix-socket $(API_SOCK) http://localhost/metrics | jq .

run-go:
	sudo -E $(which go) run main.go

git-reset: ## git-reset
	cd /ilya/microvm
	git reset --hard HEAD
	git pull origin main