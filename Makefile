# ---------------------------------------------------------------------------#
# Firecracker microVM  (alpine-rootfs.ext4, < 2 s boot, SSH ready)           #
# ---------------------------------------------------------------------------#
FC_BIN     := /usr/local/bin/firecracker
KERNEL_IMG := hello-vmlinux.bin
ROOTFS_IMG := alpine-rootfs.ext4
MACH       := machine
API_SOCK   := $(MACH)/fc.sock
SERIAL_SOCK:= $(MACH)/serial.sock
LOG_FILE   := $(MACH)/fc.log
METRICS    := $(MACH)/fc.metrics
BOOT_JSON  := $(MACH)/boot-source.json
DRIVE_JSON := $(MACH)/root-drive.json

TAP  := tap0
HOST := 172.16.0.1
GUEST:= 172.16.0.2
MASK := 255.255.255.0

.PHONY: all rootfs setup net run ssh console clean
all: rootfs setup net run

# --------------------------------------------------------------------------- rootfs
rootfs:
	@if [ ! -f $(ROOTFS_IMG) ]; then \
	    echo "🏗  Need $(ROOTFS_IMG) — building …"; \
	    sudo ./build-rootfs.sh ; \
	fi

# --------------------------------------------------------------------------- json
setup:
	@mkdir -p $(MACH) ; touch $(LOG_FILE) $(METRICS)
	@printf '{\n "kernel_image_path":"%s",\n "boot_args":"console=ttyS0 reboot=k panic=1 pci=off virtio_mmio.device=4K@0xd0000000:5 root=/dev/vda rw ip=%s::%s:%s::eth0:off quiet"\n}\n' \
	    "$(abspath $(KERNEL_IMG))" $(GUEST) $(HOST) $(MASK) > $(BOOT_JSON)
	@printf '{\n "drive_id":"rootfs",\n "path_on_host":"%s",\n "is_root_device":true,\n "is_read_only":false\n}\n' \
	    "$(abspath $(ROOTFS_IMG))" > $(DRIVE_JSON)

# --------------------------------------------------------------------------- tap
net:
	@if ! ip link show $(TAP) &>/dev/null; then \
	    echo "🔌  creating $(TAP)"; \
	    sudo ip tuntap add dev $(TAP) mode tap user $$(id -un); \
	    sudo ip addr add $(HOST)/24 dev $(TAP); \
	    sudo ip link set $(TAP) up; \
	fi
	@sudo sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
	@sudo iptables -C POSTROUTING -t nat -s $(GUEST)/32 -j MASQUERADE 2>/dev/null || \
	  sudo iptables -A POSTROUTING -t nat -s $(GUEST)/32 -j MASQUERADE

# --------------------------------------------------------------------------- run
run:
	@rm -f $(SERIAL_SOCK)
	$(FC_BIN) --api-sock $(API_SOCK) --log-path $(LOG_FILE) --metrics-path $(METRICS) & \
	FC_PID=$$! ; \
	while [ ! -S $(API_SOCK) ]; do sleep .1; done; \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H 'Content-Type: application/json' -d @$(BOOT_JSON)  http://localhost/boot-source ; \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H 'Content-Type: application/json' -d @$(DRIVE_JSON) http://localhost/drives/rootfs ; \
	# serial endpoint for Firecracker ≤ 1.6 ------------------------------- \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H 'Content-Type: application/json' \
	     -d '{"path":"$(abspath $(SERIAL_SOCK))"}' http://localhost/serial-console ; \
	curl -sS --unix-socket $(API_SOCK) -X PUT -H 'Content-Type: application/json' \
	     -d '{"action_type":"InstanceStart"}' http://localhost/actions ; \
	echo "✅  microVM started — wait 3 s then “make ssh”"; \
	wait $$FC_PID

# --------------------------------------------------------------------------- helpers
ssh: ; ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$(GUEST)
console: ; socat -d -d PTY,raw,echo=0,link=/tmp/fc-serial UNIX-CONNECT:$(SERIAL_SOCK) & sleep 1 ; screen /tmp/fc-serial
clean: ; killall firecracker 2>/dev/null || true ; sudo ip link del $(TAP) 2>/dev/null || true ; rm -rf $(MACH) /tmp/fc-serial


git-reset: ## git-reset
	cd /ilya/microvm
	git reset --hard HEAD
	git pull origin main