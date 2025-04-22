FC_BIN          := /usr/local/bin/firecracker
KERNEL_IMG := hello-vmlinux.bin
ROOTFS_IMG := hello-rootfs.ext4
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
