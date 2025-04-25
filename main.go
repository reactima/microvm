package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	fc "github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"github.com/sirupsen/logrus"
)

const (
	kernel  = "hello-vmlinux.bin"  // built by Makefile
	rootfs  = "alpine-rootfs.ext4" // built by build-rootfs.sh
	hostDev = "tap0"               // created by `make net`
	hostGW  = "172.16.0.1"
)

// reflinkOrCopy creates vm-local ext4 by hard-clone (reflink) if the FS supports
// it, falling back to a plain copy.  Result ~instant on modern filesystems.
func reflinkOrCopy(dst, src string) error {
	// Try FICLONE ioctl (btrfs/xfs/ext4-reflink/APFS)
	if err := fc.Ficlonerange(dst, src); err == nil {
		return nil
	}
	// fall back: plain copy
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func spawn(idx int, ip string, baseLog *logrus.Logger) {
	vmID := fmt.Sprintf("vm%d", idx)
	dir := filepath.Join("machine", vmID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		baseLog.Fatalf("mkdir %s: %v", dir, err)
	}

	// Per-VM rootfs ­– fast reflink if possible
	vmRoot := filepath.Join(dir, "rootfs.ext4")
	if err := reflinkOrCopy(vmRoot, rootfs); err != nil {
		baseLog.Fatalf("rootfs clone: %v", err)
	}

	cfg := fc.Config{
		SocketPath:      filepath.Join(dir, "fc.sock"),
		LogFifo:         filepath.Join(dir, "fc.log.fifo"),
		MetricsFifo:     filepath.Join(dir, "fc.metrics.fifo"),
		KernelImagePath: kernel,
		KernelArgs:      "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw quiet",
		Drives: []models.Drive{{
			DriveID:      fc.String("rootfs"),
			PathOnHost:   fc.String(vmRoot),
			IsRootDevice: fc.Bool(true),
		}},
		NetworkInterfaces: fc.NetworkInterfaces{{
			StaticConfiguration: &fc.StaticNetworkConfiguration{
				HostDevName: hostDev,
				MacAddress:  fmt.Sprintf("AA:FC:00:00:%02d:%02d", idx, idx),
				IPConfiguration: &fc.IPConfiguration{
					IPAddr:  fc.MustParseCIDR(ip + "/24"),
					Gateway: fc.MustParseIP(hostGW),
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

	entry := logrus.NewEntry(baseLog).WithField("vm", vmID)
	m, err := fc.NewMachine(ctx, cfg, fc.WithLogger(entry))
	if err != nil {
		entry.Fatalf("new: %v", err)
	}
	if err := m.Start(ctx); err != nil {
		entry.Fatalf("start: %v", err)
	}
	entry.Infof("up → ssh root@%s (pwd firecracker)", ip)

	go m.Wait(context.Background()) // reap when it exits
}

func main() {
	log := logrus.New()
	log.SetFormatter(&logrus.TextFormatter{FullTimestamp: true})

	spawn(0, "172.16.0.10", log)
	spawn(1, "172.16.0.11", log)
	spawn(2, "172.16.0.12", log)

	select {} // keep host alive
}
