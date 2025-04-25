// cmd/spawn/spawn.go
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"time"

	fc "github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"golang.org/x/sys/unix"
)

const (
	kernel  = "hello-vmlinux.bin"  // built by Makefile
	rootfs  = "alpine-rootfs.ext4" // built by build-rootfs.sh
	hostDev = "tap0"               // created by `make net`
	hostGW  = "172.16.0.1"         // host address inside /24
)

/*
cloneRootfs overlays the readonly golden ext4 with a tmpfs COW layer so every
VM sees a clean, writable FS but they share >90 % of the bytes on disk.
*/
func cloneRootfs(idx int) string {
	upper := filepath.Join("machine", fmt.Sprintf("cow%d", idx))
	if err := os.MkdirAll(upper, 0o755); err != nil {
		log.Fatalf("mkdir %s: %v", upper, err)
	}
	overlay := filepath.Join("machine", fmt.Sprintf("rootfs%d.img", idx))
	if err := unix.Mount(rootfs, upper, "overlay",
		0, fmt.Sprintf("lowerdir=%s,upperdir=%s,workdir=%s_work", rootfs, upper, upper)); err != nil {
		log.Fatalf("overlay mount: %v (is the module loaded?)", err)
	}
	// We just return the upperdir; Firecracker doesn’t care it’s overlay-backed.
	return upper
}

func spawn(idx int, ip string) {
	vmID := fmt.Sprintf("vm%d", idx)
	dir := filepath.Join("machine", vmID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		log.Fatal(err)
	}

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
					IPAddr: net.IPNet{
						IP:   net.ParseIP(ip),
						Mask: net.CIDRMask(24, 32),
					},
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

	m, err := fc.NewMachine(ctx, cfg,
		fc.WithLogger(log.New(os.Stdout, "["+vmID+"] ", log.LstdFlags)))
	if err != nil {
		log.Fatalf("%s new: %v", vmID, err)
	}
	if err := m.Start(ctx); err != nil {
		log.Fatalf("%s start: %v", vmID, err)
	}
	log.Printf("%s up → ssh root@%s  (pwd firecracker)", vmID, ip)
	go m.Wait(context.Background())
}

func main() {
	// Preconditions: `make rootfs setup net` already run.
	spawn(0, "172.16.0.10")
	spawn(1, "172.16.0.11")
	spawn(2, "172.16.0.12")
	select {}
}
