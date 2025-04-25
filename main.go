// main.go – three microVMs on bridge fcbr0

package main

import (
	"context"
	fc "github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
)

const (
	kernel     = "hello-vmlinux.bin"
	rootfs     = "alpine-rootfs.ext4"
	bridge     = "fcbr0"
	hostGW     = "172.16.0.1"
	subnetCIDR = "172.16.0.0/24"
	memPerVM   = 96 // MiB
)

var log = logrus.New()

/* ---------- host-side helpers ------------------------------------------------ */

func sh(args ...string) *exec.Cmd { return exec.Command("sudo", args...) }

func ensureBridge() {
	if _, err := os.Stat("/sys/class/net/" + bridge); os.IsNotExist(err) {
		log.Info("creating bridge " + bridge)
		_ = sh("ip", "link", "add", "name", bridge, "type", "bridge").Run()
		_ = sh("ip", "addr", "add", hostGW+"/24", "dev", bridge).Run()
		_ = sh("ip", "link", "set", bridge, "up").Run()
	}
	// one-time NAT
	if err := sh("iptables", "-t", "nat", "-C", "POSTROUTING",
		"-s", subnetCIDR, "-j", "MASQUERADE").Run(); err != nil {
		_ = sh("iptables", "-t", "nat", "-A", "POSTROUTING",
			"-s", subnetCIDR, "-j", "MASQUERADE").Run()
	}
}

func attachTap(tap string) {
	_ = sh("ip", "tuntap", "add", "dev", tap, "mode", "tap").Run()
	_ = sh("ip", "link", "set", tap, "master", bridge).Run()
	_ = sh("ip", "link", "set", tap, "up").Run()
}

/* ---------- CoW rootfs ------------------------------------------------------- */

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

/* ---------- VM spawn --------------------------------------------------------- */

func spawn(idx int, ip string) {
	vmID := "vm" + ip[len(ip)-2:] // vm10, vm11 …
	dir := filepath.Join("machine", vmID)
	_ = os.MkdirAll(dir, 0o755)

	dst := filepath.Join(dir, "rootfs.ext4")
	if err := reflinkOrCopy(dst, rootfs); err != nil {
		log.Fatalf("[%s] clone rootfs: %v", vmID, err)
	}

	tap := "tapfc" + ip[len(ip)-2:]
	attachTap(tap)

	_, ipNet, _ := net.ParseCIDR(ip + "/24")

	cfg := fc.Config{
		SocketPath:      filepath.Join(dir, "fc.sock"),
		LogFifo:         filepath.Join(dir, "fc.log.fifo"),
		MetricsFifo:     filepath.Join(dir, "fc.metrics.fifo"),
		KernelImagePath: kernel,
		KernelArgs:      "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw quiet",
		Drives: []models.Drive{{
			DriveID:      fc.String("rootfs"),
			PathOnHost:   fc.String(dst),
			IsRootDevice: fc.Bool(true),
		}},
		NetworkInterfaces: fc.NetworkInterfaces{{
			StaticConfiguration: &fc.StaticNetworkConfiguration{
				HostDevName: tap,
				MacAddress:  "AA:FC:00:00:" + ip[len(ip)-2:] + ":" + ip[len(ip)-2:],
				IPConfiguration: &fc.IPConfiguration{
					IPAddr:  *ipNet,
					Gateway: net.ParseIP(hostGW),
				},
			},
		}},
		MachineCfg: models.MachineConfiguration{
			MemSizeMib: fc.Int64(memPerVM),
			VcpuCount:  fc.Int64(1),
		},
		VMID: vmID,
	}

	entry := log.WithField("vm", vmID)
	m, err := fc.NewMachine(context.Background(), cfg, fc.WithLogger(entry))
	if err != nil {
		entry.Fatalf("new: %v", err)
	}
	if err := m.Start(context.Background()); err != nil {
		entry.Fatalf("start: %v", err)
	}
	entry.Infof("up → ssh root@%s  (pwd firecracker)", ip)
	go m.Wait(context.Background())
}

/* ---------- main ------------------------------------------------------------ */

func main() {
	log.SetFormatter(&logrus.TextFormatter{FullTimestamp: true})
	ensureBridge()

	spawn(0, "172.16.0.10")
	spawn(1, "172.16.0.11")
	spawn(2, "172.16.0.12")

	select {} // keep host alive
}
