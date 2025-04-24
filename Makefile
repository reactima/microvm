# Firecracker microVM – build Alpine rootfs → boot → SSH
FC_BIN          := /usr/local/bin/firecracker
KERNEL_IMG      := hello-vmlinux.bin
ROOTFS_IMG      := alpine-rootfs.ext4
MACHINE_DIR     := machine
API_SOCKET      := $(MACHINE_DIR)/fc.sock
SERIAL_SOCK     := $(MACHINE_DIR)/serial.sock
LOG_FILE        := $(MACHINE_DIR)/fc.log
METRICS_FILE    := $(MACHINE_DIR)/fc.metrics
BOOT_CFG_FILE   := $(MACHINE_DIR)/boot-source.json
DRIVE_CFG_FILE  := $(MACHINE_DIR)/root-drive.json
# network
TAP_DEV  := tap0
HOST_IP  := 172.16.0.1
GUEST_IP := 172.16.0.2
NETMASK  := 255.255.255.0
.PHONY: all rootfs setup net run console ssh clean
# -------------------------------------------------------------------------
# default: ensure rootfs exists → generate configs → net → boot
all: rootfs setup net run
# -------------------------------------------------------------------------
rootfs:
	@test -f $(ROOTFS_IMG) || { \
	  echo "🏗  Building Alpine rootfs …" ; \
	  sudo ./build-rootfs.sh ; \
	}
# -------------------------------------------------------------------------
setup:
	@mkdir -p $(MACHINE_DIR) ; touch $(LOG_FILE) $(METRICS_FILE)
	@printf '{\n "kernel_image_path":"%s",\n "boot_args":"console=ttyS0 reboot=k panic=1 pci=off init=/sbin/init ip=%s::%s:%s::eth0:off root=/dev/vda rw"\n}\n' \
	    "$(abspath $(KERNEL_IMG))" $(GUEST_IP) $(HOST_IP) $(NETMASK) > $(BOOT_CFG_FILE)
	@printf '{\n "drive_id":"rootfs",\n "path_on_host":"%s",\n "is_root_device":true,\n "is_read_only":false\n}\n' \
	    "$(abspath $(ROOTFS_IMG))" > $(DRIVE_CFG_FILE)
# -------------------------------------------------------------------------
net:
	@if ! ip link show $(TAP_DEV) >/dev/null 2>&1; then \
	  echo "🔌 Creating $(TAP_DEV) …" ; \
	  sudo ip tuntap add dev $(TAP_DEV) mode tap user $$(id -un) ; \
	  sudo ip addr add $(HOST_IP)/24 dev $(TAP_DEV) ; \
	  sudo ip link set $(TAP_DEV) up ; \
	fi
	@sudo sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
	@sudo iptables -C POSTROUTING -t nat -s $(GUEST_IP)/32 -j MASQUERADE 2>/dev/null || \
	  sudo iptables -A POSTROUTING -t nat -s $(GUEST_IP)/32 -j MASQUERADE
	@echo "🌐 $(TAP_DEV) ready ($(HOST_IP) ⇆ $(GUEST_IP))"
# -------------------------------------------------------------------------
run:
	@echo "🔥 Launching microVM …"
	@rm -f $(SERIAL_SOCK)
	$(FC_BIN) --api-sock $(API_SOCKET) --log-path $(LOG_FILE) --metrics-path $(METRICS_FILE) & \
	FC_PID=$$! ; \
	while [ ! -S $(API_SOCKET) ]; do sleep .1; done ; \
	curl -sS --unix-socket $(API_SOCKET) -X PUT -H 'Content-Type: application/json' -d @$(BOOT_CFG_FILE) http://localhost/boot-source ; \
	curl -sS --unix-socket $(API_SOCKET) -X PUT -H 'Content-Type: application/json' -d @$(DRIVE_CFG_FILE) http://localhost/drives/rootfs ; \
	curl -sS --unix-socket $(API_SOCKET) -X PUT -H 'Content-Type: application/json' -d '{"id":"Serial0","tty_path":"$(abspath $(SERIAL_SOCK))"}' http://localhost/serial-ports/0 ; \
	curl -sS --unix-socket $(API_SOCKET) -X PUT -H 'Content-Type: application/json' -d '{"action_type":"InstanceStart"}' http://localhost/actions ; \
	echo "✅ VM running — wait 5 s then \`make ssh\` or \`make console\`" ; \
	wait $$FC_PID
# -------------------------------------------------------------------------
console:
	@command -v socat >/dev/null || { echo "❌ socat not installed" ; exit 1 ; }
	@socat -d -d PTY,raw,echo=0,link=/tmp/fc-serial UNIX-CONNECT:$(SERIAL_SOCK) & \
	sleep 1 ; screen /tmp/fc-serial
# -------------------------------------------------------------------------
ssh:
	@echo "🔑 Connecting via SSH …"
	@ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$(GUEST_IP)
# -------------------------------------------------------------------------
clean:
	@echo "🧹 Cleaning up …"
	-@killall firecracker 2>/dev/null || true
	-@sudo ip link del $(TAP_DEV) 2>/dev/null || true
	@rm -rf $(MACHINE_DIR) /tmp/fc-serial

git-reset: ## git-reset
	cd /ilya/microvm
	git reset --hard HEAD
	git pull origin main