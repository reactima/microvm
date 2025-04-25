// cmd/spawn-slog/main.go
package main

import (
	"context"
	"fmt"
	"log/slog"
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
	hostGW  = "172.16.0.1"
)

/* ----------------------------- slog adapter ------------------------------ */

type slogAdapter struct{ *slog.Logger }

func (l slogAdapter) Debugf(f string, v ...interface{}) { l.Debug(fmt.Sprintf(f, v...)) }
func (l slogAdapter) Infof(f string, v ...interface{})  { l.Info(fmt.Sprintf(f, v...)) }
func (l slogAdapter) Warnf(f string, v ...interface{})  { l.Warn(fmt.Sprintf(f, v...)) }
func (l slogAdapter) Errorf(f string, v ...interface{}) { l.Error(fmt.Sprintf(f, v...)) }

/* --------------------------- overlay rootfs COW -------------------------- */

func cloneRootfs(idx int) string {
	cow := filepath.Join("machine", fmt.Sprintf("cow%d", idx))
	_ = os.MkdirAll(cow, 0o755)
	if err := unix.Mount(rootfs, cow, "overlay", 0,
		fmt.Sprintf("lowerdir=%s,upperdir=%s,workdir=%s_work", rootfs, cow, cow)); err != nil {
		panic("overlayfs mount failed (modprobe overlay?) ⇒ " + err.Error())
	}
	return cow
}

/* ------------------------------ VM spawner ------------------------------- */

func spawn(idx int, ip string, lg *slog.Logger) {
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
			DriveID: fc.String("rootfs"), PathOnHost: fc.String(cloneRootfs(idx)),
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
			MemSizeMib: fc.Int64(96), VcpuCount: fc.Int64(1),
		},
		VMID: vmID,
	}

	// Firecracker expects its own logger interface; wrap slog.
	logger := slogAdapter{lg.With("vm", vmID)}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	m, err := fc.NewMachine(ctx, cfg, fc.WithLogger(logger))
	if err != nil {
		logger.Errorf("new: %v", err)
		return
	}

	if err := m.Start(ctx); err != nil {
		logger.Errorf("start: %v", err)
		return
	}

	logger.Infof("up → ssh root@%s (pwd firecracker)", ip)
	go m.Wait(context.Background())
}

/* --------------------------------- main ---------------------------------- */

func main() {
	lg := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	spawn(0, "172.16.0.10", lg)
	spawn(1, "172.16.0.11", lg)
	spawn(2, "172.16.0.12", lg)

	select {} // keep program alive
}
