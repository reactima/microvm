package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
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

func must(cmd ...string) {
	c := exec.Command(cmd[0], cmd[1:]...)
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		log.Fatalf("cmd %v: %v", cmd, err)
	}
}

/* ---------- host net ------------------------------------------------------ */

func ensureRoot() {
	if os.Geteuid() != 0 {
		log.Fatal("run with: sudo make run-go   (needs root)")
	}
}
func bridgeUp() {
	if _, err := os.Stat("/sys/class/net/" + bridge); os.IsNotExist(err) {
		must("ip", "link", "add", bridge, "type", "bridge")
		must("ip", "addr", "add", hostCIDR, "dev", bridge)
		must("ip", "link", "set", bridge, "up")
	}
	if exec.Command("iptables", "-t", "nat", "-C", "POSTROUTING",
		"-s", subnet, "-j", "MASQUERADE").Run() != nil {
		must("iptables", "-t", "nat", "-A", "POSTROUTING",
			"-s", subnet, "-j", "MASQUERADE")
	}
}
func mkTap(name string) {
	_ = exec.Command("ip", "link", "del", name).Run()
	must("ip", "tuntap", "add", name, "mode", "tap")
	must("ip", "link", "set", name, "master", bridge)
	must("ip", "link", "set", name, "up")
}

/* ---------- CoW rootfs ---------------------------------------------------- */

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

/* ---------- spawn VM ------------------------------------------------------ */

func spawn(ip string) {
	suffix := ip[strings.LastIndex(ip, ".")+1:] // "10"
	vmID := "vm" + suffix
	dir := filepath.Join("machine", vmID)
	_ = os.MkdirAll(dir, 0o755)

	vmRoot := filepath.Join(dir, "rootfs.ext4")
	if err := reflinkOrCopy(vmRoot, rootfs); err != nil {
		log.Fatalf("[%s] rootfs clone: %v", vmID, err)
	}

	tap := "tapfc" + suffix
	mkTap(tap)

	kargs := fmt.Sprintf(
		"console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw ip=%s::%s:255.255.255.0::eth0:off",
		ip, hostGW)

	_, ipNet, _ := net.ParseCIDR(ip + "/24")

	cfg := fc.Config{
		SocketPath:      filepath.Join(dir, "fc.sock"),
		LogFifo:         filepath.Join(dir, "fc.log.fifo"),
		MetricsFifo:     filepath.Join(dir, "fc.metrics.fifo"),
		KernelImagePath: kernel,
		KernelArgs:      kargs,
		Drives: []models.Drive{{
			DriveID:      fc.String("rootfs"),
			PathOnHost:   fc.String(vmRoot),
			IsRootDevice: fc.Bool(true),
		}},
		NetworkInterfaces: fc.NetworkInterfaces{{
			StaticConfiguration: &fc.StaticNetworkConfiguration{
				HostDevName: tap,
				MacAddress:  "AA:FC:00:00:" + suffix + ":" + suffix,
				IPConfiguration: &fc.IPConfiguration{
					IPAddr:  *ipNet,
					Gateway: net.ParseIP(hostGW),
				},
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

/* ---------- main ---------------------------------------------------------- */

func main() {
	ensureRoot()
	bridgeUp()
	for _, ip := range []string{"172.16.0.10", "172.16.0.11", "172.16.0.12"} {
		spawn(ip)
	}
	select {}
}
