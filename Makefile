FC_BIN          := /usr/local/bin/firecracker
KERNEL_IMG := hello-vmlinux.bin
ROOTFS_IMG := hello-rootfs.ext4
MACHINE_DIR     := machine
API_SOCKET      := $(MACHINE_DIR)/fc.sock
SERIAL_SOCK      := $(MACHINE_DIR)/serial.sock
LOG_FILE        := $(MACHINE_DIR)/fc.log
METRICS_FILE    := $(MACHINE_DIR)/fc.metrics
BOOT_CFG_FILE   := $(MACHINE_DIR)/boot-source.json
DRIVE_CFG_FILE  := $(MACHINE_DIR)/root-drive.json

# ---------- network ----------------------------------------------------------
TAP_DEV          := tap0
HOST_IP          := 172.16.0.1
GUEST_IP         := 172.16.0.2
NETMASK          := 255.255.255.0

# ---------- phony targets ----------------------------------------------------
.PHONY: all setup net run console ssh clean

setup:
	mkdir -p $(MACHINE_DIR)
	touch $(LOG_FILE) $(METRICS_FILE)
	@echo "Generating $(BOOT_CFG_FILE)"
	@echo '{'                                    > $(BOOT_CFG_FILE)
	@echo '  "kernel_image_path": "$(abspath $(KERNEL_IMG))",' >> $(BOOT_CFG_FILE)
	@echo '  "boot_args": "console=ttyS0 reboot=k panic=1 pci=off init=/bin/sh"' >> $(BOOT_CFG_FILE)
	@echo '}'                                   >> $(BOOT_CFG_FILE)
	@echo "Generating $(DRIVE_CFG_FILE)"
	@echo '{'                                    > $(DRIVE_CFG_FILE)
	@echo '  "drive_id": "rootfs",'              >> $(DRIVE_CFG_FILE)
	@echo '  "path_on_host": "$(abspath $(ROOTFS_IMG))",' >> $(DRIVE_CFG_FILE)
	@echo '  "is_root_device": true,'            >> $(DRIVE_CFG_FILE)
	@echo '  "is_read_only": false'              >> $(DRIVE_CFG_FILE)
	@echo '}'                                   >> $(DRIVE_CFG_FILE)

# -----------------------------------------------------------------------------#
# 2.  Bring up a tap interface for the VM (needs sudo once)
# -----------------------------------------------------------------------------#
net:
	@if ! ip link show $(TAP_DEV) >/dev/null 2>&1; then \
	    echo "🔌 Creating $(TAP_DEV) …"; \
	    sudo ip tuntap add dev $(TAP_DEV) mode tap user $$(id -un); \
	    sudo ip addr add $(HOST_IP)/24 dev $(TAP_DEV); \
	    sudo ip link set $(TAP_DEV) up; \
	fi
	@sudo sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
	@sudo iptables -C POSTROUTING -t nat -s $(GUEST_IP)/32 ! -d $(GUEST_IP)/32 -j MASQUERADE 2>/dev/null || \
	    sudo iptables -A POSTROUTING -t nat -s $(GUEST_IP)/32 ! -d $(GUEST_IP)/32 -j MASQUERADE
	@echo "🌐 $(TAP_DEV) ready  ($(HOST_IP) ⇆ $(GUEST_IP))"

# -----------------------------------------------------------------------------#
# 3.  Start Firecracker, attach serial socket & network
# -----------------------------------------------------------------------------#
run:
	@echo "🔥 Launching microVM …"
	@mkdir -p $(MACHINE_DIR)
	@touch $(LOG_FILE) $(METRICS_FILE)
	@rm -f $(SERIAL_SOCK)
	$(FC_BIN) --api-sock $(API_SOCKET) \
		--log-path $(LOG_FILE) \
	          --metrics-path $(METRICS_FILE) & \
	FC_PID=$$!; \
	while [ ! -S $(API_SOCKET) ]; do sleep .1; done; \
	echo "⚙️  Pushing boot/drive/serial configs …"; \
	curl --silent --unix-socket $(API_SOCKET) -X PUT -H 'Content-Type: application/json' \
	     -d @$(BOOT_CFG_FILE) http://localhost/boot-source ; \
	curl --silent --unix-socket $(API_SOCKET) -X PUT -H 'Content-Type: application/json' \
	     -d @$(DRIVE_CFG_FILE) http://localhost/drives/rootfs ; \
	curl --silent --unix-socket $(API_SOCKET) -X PUT -H 'Content-Type: application/json' \
	     -d '{"id":"Serial0","tty_path":"$(abspath $(SERIAL_SOCK))"}' \
	     http://localhost/serial-ports/0 ; \
	curl --silent --unix-socket $(API_SOCKET) -X PUT -H 'Content-Type: application/json' \
	     -d '{"action_type":"InstanceStart"}' http://localhost/actions ; \
	echo "✅ VM started (PID $$FC_PID) — use \`make console\` or \`make ssh\`"; \
	wait $$FC_PID

# -----------------------------------------------------------------------------#
# 4a.  Attach to guest console via PTY (needs socat & screen/minicom)
# -----------------------------------------------------------------------------#
console:
	@command -v socat >/dev/null || { echo "❌ socat not installed"; exit 1; }
	@socat -d -d PTY,raw,echo=0,link=/tmp/fc-serial UNIX-CONNECT:$(SERIAL_SOCK) & \
	sleep 1; \
	echo "🖥️  Console PTY: /tmp/fc-serial — opening with screen …"; \
	screen /tmp/fc-serial

# -----------------------------------------------------------------------------#
# 4b.  SSH convenience wrapper (root@172.16.0.2) ------------------------------#
#      Requires your rootfs to run an SSH daemon (dropbear/openssh).           #
# -----------------------------------------------------------------------------#
ssh:
	@echo "🔑 Connecting via SSH …"
	@ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$(GUEST_IP)

# -----------------------------------------------------------------------------#
# 5. Tear everything down
# -----------------------------------------------------------------------------#
clean:
	@echo "Cleaning up..."
	-killall firecracker 2>/dev/null || true
	rm -rf $(MACHINE_DIR)
