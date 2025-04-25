// main.go – spin up three Firecracker microVMs backed by reflinked rootfs
package main

import (
	"context"
	"fmt"
	"io"
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
	kernel  = "hello-vmlinux.bin"  // built by Makefile
	rootfs  = "alpine-rootfs.ext4" // built by build-rootfs.sh
	hostDev = "tap0"               // created by `make net`
	hostGW  = "172.16.0.1"         // gateway inside /24
)

// reflinkOrCopy tries the FICLONE ioctl; falls back to io.Copy on filesystems
// that don’t support it (ext4 w/o reflink, ext3, etc.).
func reflinkOrCopy(dst, src string) error {
	srcFd, err := os.Open(src)
	if err != nil {
		return err
	}
	defer srcFd.Close()

	dstFd, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer dstFd.Close()

	// Linux FICLONE=0x40049409  (see linux/fs.h)
	const ficlone = 0x40049409
	if err := unix.IoctlSetInt(int(dstFd.Fd()), ficlone, int(srcFd.Fd())); err == nil {
		return nil // reflink succeeded 🎉
	}

	// slow path: plain copy
	_, err = io.Copy(dstFd, srcFd)
	return err
}

func spawn(idx int, ip string, baseLog *logrus.Logger) {
	vmID := fmt.Sprintf("vm%d", idx)
	dir := filepath.Join("machine", vmID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		baseLog.Fatalf("mkdir %s: %v", dir, err)
	}

	// per-VM writable rootfs
	vmRoot := filepath.Join(dir, "rootfs.ext4")
	if err := reflinkOrCopy(vmRoot, rootfs); err != nil {
		baseLog.Fatalf("clone rootfs: %v", err)
	}

	_, ipNet, err := net.ParseCIDR(ip + "/24")
	if err != nil {
		baseLog.Fatalf("CIDR parse: %v", err)
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
					IPAddr:  *ipNet,
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

	entry := logrus.NewEntry(baseLog).WithField("vm", vmID)
	m, err := fc.NewMachine(ctx, cfg, fc.WithLogger(entry))
	if err != nil {
		entry.Fatalf("new: %v", err)
	}
	if err := m.Start(ctx); err != nil {
		entry.Fatalf("start: %v", err)
	}
	entry.Infof("up → ssh root@%s  (pwd firecracker)", ip)

	go m.Wait(context.Background()) // reap when the VM exits
}

func main() {
	log := logrus.New()
	log.SetFormatter(&logrus.TextFormatter{FullTimestamp: true})

	spawn(0, "172.16.0.10", log)
	spawn(1, "172.16.0.11", log)
	spawn(2, "172.16.0.12", log)

	select {} // keep microVMs alive
}
