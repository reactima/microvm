FC_BIN          := /usr/local/bin/firecracker
KERNEL_IMG      := vmlinux.bin
ROOTFS_IMG      := rootfs.ext4
MACHINE_DIR     := machine
API_SOCKET      := $(MACHINE_DIR)/fc.sock
LOG_FILE        := $(MACHINE_DIR)/fc.log
METRICS_FILE    := $(MACHINE_DIR)/fc.metrics
BOOT_CFG_FILE   := $(MACHINE_DIR)/boot-source.json
DRIVE_CFG_FILE  := $(MACHINE_DIR)/root-drive.json

.PHONY: all setup run clean

all: setup run

setup:
	mkdir -p $(MACHINE_DIR)
	touch $(LOG_FILE) $(METRICS_FILE)

	# Generate boot-source config
	@echo "Generating $(BOOT_CFG_FILE)"
	@cat <<EOF > $(BOOT_CFG_FILE)
{
  "kernel_image_path": "$(abspath $(KERNEL_IMG))",
  "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
}
EOF

	# Generate root drive config
	@echo "Generating $(DRIVE_CFG_FILE)"
	@cat <<EOF > $(DRIVE_CFG_FILE)
{
  "drive_id": "rootfs",
  "path_on_host": "$(abspath $(ROOTFS_IMG))",
  "is_root_device": true,
  "is_read_only": false
}
EOF

run:
	@echo "Starting Firecracker..."
	mkdir -p $(MACHINE_DIR)
	touch $(LOG_FILE) $(METRICS_FILE)
	$(FC_BIN) \
		--api-sock $(API_SOCKET) \
		--log-path $(LOG_FILE) \
		--metrics-path $(METRICS_FILE) < /dev/null & \
	FC_PID=$$!; \
	while [ ! -S $(API_SOCKET) ]; do sleep .1; done; \
	curl --unix-socket $(API_SOCKET) -sS \
		-X PUT "http://localhost/boot-source" \
		-H "Accept: application/json" \
		-H "Content-Type: application/json" \
		-d @$(BOOT_CFG_FILE); \
	curl --unix-socket $(API_SOCKET) -sS \
		-X PUT "http://localhost/drives/rootfs" \
		-H "Accept: application/json" \
		-H "Content-Type: application/json" \
		-d @$(DRIVE_CFG_FILE); \
	curl --unix-socket $(API_SOCKET) -sS \
		-X PUT "http://localhost/actions" \
		-H "Accept: application/json" \
		-H "Content-Type: application/json" \
		-d '{"action_type":"InstanceStart"}'; \
	wait $$FC_PID

clean:
	@echo "Cleaning up..."
	-killall firecracker 2>/dev/null || true
	rm -rf $(MACHINE_DIR)
