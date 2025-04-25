package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"

	fc "github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
)

const (
	kernel  = "hello-vmlinux.bin"
	rootfs  = "alpine-rootfs.ext4"
	hostDev = "tap0"
	hostGW  = "172.16.0.1"
)

// overlay-mounted, copy-on-write rootfs
func cloneRootfs(idx int) string {
	upper := filepath.Join("machine", fmt.Sprintf("cow%d", idx))
	_ = os.MkdirAll(upper, 0o755)
	if err := unix.Mount(rootfs, upper, "overlay", 0,
		fmt.Sprintf("lowerdir=%s,upperdir=%s,workdir=%s_work", rootfs, upper, upper)); err != nil {
		panic(err) // overlayfs module missing?
	}
	return upper
}

func spawn(idx int, ip string, baseLog *logrus.Logger) {
	vmID := fmt.Sprintf("vm%d", idx)
	dir := filepath.Join("machine", vmID)
	_ = os.MkdirAll(dir, 0o755)

	cfg := fc.Config{
		SocketPath:      filepath.Join(dir, "fc.sock"),
		LogFifo:         filepath.Join(dir, "fc.log.fifo"),
		MetricsFifo:     filepath.Join(dir, "fc.metrics.fifo"),
		KernelImagePath: kernel,
		KernelArgs:      "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw quiet",
		Drives: []models.Drive{{
			DriveID:      fc.String("rootfs"),
			PathOnHost:   fc.String(cloneRootfs(idx)),
			IsRootDevice: fc.Bool(true),
		}},
		NetworkInterfaces: fc.NetworkInterfaces{{
			StaticConfiguration: &fc.StaticNetworkConfiguration{
				HostDevName: hostDev,
				MacAddress:  fmt.Sprintf("AA:FC:00:00:%02d:%02d", idx, idx),
				IPConfiguration: &fc.IPConfiguration{
					IPAddr:  net.IPNet{IP: net.ParseIP(ip), Mask: net.CIDRMask(24, 32)},
					Gateway: net.ParseIP(hostGW),
				},
			},
		}},
		MachineCfg: models.MachineConfiguration{
			MemSizeMib: fc.Int64(96),
			VcpuCount:  fc.Int64(1),
		},
		VMID: vmID,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	logEntry := logrus.NewEntry(baseLog).WithField("vm", vmID)

	m, err := fc.NewMachine(ctx, cfg, fc.WithLogger(logEntry))
	if err != nil {
		logEntry.Fatalf("new: %v", err)
	}

	if err := m.Start(ctx); err != nil {
		logEntry.Fatalf("start: %v", err)
	}

	logEntry.Infof("up → ssh root@%s (pwd firecracker)", ip)
	go m.Wait(context.Background())
}

func main() {
	logger := logrus.New()
	logger.SetFormatter(&logrus.TextFormatter{FullTimestamp: true})

	spawn(0, "172.16.0.10", logger)
	spawn(1, "172.16.0.11", logger)
	spawn(2, "172.16.0.12", logger)

	select {} // keep main alive
}
