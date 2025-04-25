// main.go – multi-VM launcher (vm10/11/12) – run with sudo.
package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	fc "github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"golang.org/x/sys/unix"
)

const (
	kernel   = "hello-vmlinux.bin"
	rootfs   = "alpine-rootfs.ext4"
	bridge   = "fcbr0"
	hostCIDR = "172.16.0.1/24"
	hostGW   = "172.16.0.1"
	subnet   = "172.16.0.0/24"
	memMB    = 96
)

func run(cmd ...string) {
	c := exec.Command(cmd[0], cmd[1:]...)
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		log.Fatalf("cmd %v: %v", cmd, err)
	}
}

func ensureRoot() {
	if os.Geteuid() != 0 {
		log.Fatal("run with: sudo make run-go")
	}
}

func bridgeUp() {
	if _, err := os.Stat("/sys/class/net/" + bridge); os.IsNotExist(err) {
		run("ip", "link", "add", bridge, "type", "bridge")
		run("ip", "addr", "add", hostCIDR, "dev", bridge)
		run("ip", "link", "set", bridge, "up")
	}
	if exec.Command("iptables", "-t", "nat", "-C", "POSTROUTING",
		"-s", subnet, "-j", "MASQUERADE").Run() != nil {
		run("iptables", "-t", "nat", "-A", "POSTROUTING",
			"-s", subnet, "-j", "MASQUERADE")
	}
}

func mkTap(name string) {
	_ = exec.Command("ip", "link", "del", name).Run()
	run("ip", "tuntap", "add", name, "mode", "tap")
	run("ip", "link", "set", name, "master", bridge)
	run("ip", "link", "set", name, "up")
}

func reflinkOrCopy(dst, src string) error {
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
	const ficlone = 0x40049409
	if unix.IoctlSetInt(int(out.Fd()), ficlone, int(in.Fd())) == nil {
		return nil
	}
	_, err = io.Copy(out, in)
	return err
}

func spawn(ip string) {
	sfx := ip[strings.LastIndex(ip, ".")+1:]
	vmID := "vm" + sfx
	dir := filepath.Join("machine", vmID)
	_ = os.MkdirAll(dir, 0o755)

	dst := filepath.Join(dir, "rootfs.ext4")
	if err := reflinkOrCopy(dst, rootfs); err != nil {
		log.Fatalf("[%s] rootfs clone: %v", vmID, err)
	}

	tap := "tapfc" + sfx
	mkTap(tap)

	kargs := fmt.Sprintf(
		"console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw ip=%s::%s:255.255.255.0::eth0:off",
		ip, hostGW)

	cfg := fc.Config{
		SocketPath:      filepath.Join(dir, "fc.sock"),
		LogFifo:         filepath.Join(dir, "fc.log.fifo"),
		MetricsFifo:     filepath.Join(dir, "fc.metrics.fifo"),
		KernelImagePath: kernel,
		KernelArgs:      kargs,
		Drives: []models.Drive{{
			DriveID:      fc.String("rootfs"),
			PathOnHost:   fc.String(dst),
			IsRootDevice: fc.Bool(true),
		}},
		NetworkInterfaces: fc.NetworkInterfaces{{
			StaticConfiguration: &fc.StaticNetworkConfiguration{
				HostDevName: tap,
				MacAddress:  "AA:FC:00:00:" + sfx + ":" + sfx,
			},
		}},
		MachineCfg: models.MachineConfiguration{
			MemSizeMib: fc.Int64(memMB),
			VcpuCount:  fc.Int64(1),
		},
		VMID: vmID,
	}

	m, err := fc.NewMachine(context.Background(), cfg)
	if err != nil {
		log.Fatalf("[%s] new: %v", vmID, err)
	}
	if err := m.Start(context.Background()); err != nil {
		log.Fatalf("[%s] start: %v", vmID, err)
	}
	log.Printf("[%s] up → ssh root@%s (pwd firecracker)", vmID, ip)
	go m.Wait(context.Background())
}

func main() {
	ensureRoot()
	bridgeUp()
	for _, ip := range []string{"172.16.0.10", "172.16.0.11", "172.16.0.12"} {
		spawn(ip)
	}
	select {}
}
