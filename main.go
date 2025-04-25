// main.go – three VMs on bridge fcbr0; run as root.
package main

import (
	"context"
	fc "github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"golang.org/x/sys/unix"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
)

const (
	kernel     = "hello-vmlinux.bin"
	rootfs     = "alpine-rootfs.ext4"
	bridge     = "fcbr0"
	hostIP     = "172.16.0.1/24"
	hostGW     = "172.16.0.1"
	subnetCIDR = "172.16.0.0/24"
	memPerVM   = 96
)

func must(cmd *exec.Cmd) {
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatalf("cmd %v: %v", cmd.Args, err)
	}
}

func ensureRoot() {
	if os.Geteuid() != 0 {
		log.Fatal("Run this program as root: sudo go run main.go")
	}
}

/* ---------- bridge & NAT --------------------------------------------------- */

func ensureBridge() {
	if _, err := os.Stat("/sys/class/net/" + bridge); os.IsNotExist(err) {
		must(exec.Command("ip", "link", "add", bridge, "type", "bridge"))
		must(exec.Command("ip", "addr", "add", hostIP, "dev", bridge))
		must(exec.Command("ip", "link", "set", bridge, "up"))
	}

	if err := exec.Command("iptables", "-t", "nat", "-C", "POSTROUTING",
		"-s", subnetCIDR, "-j", "MASQUERADE").Run(); err != nil {
		must(exec.Command("iptables", "-t", "nat", "-A", "POSTROUTING",
			"-s", subnetCIDR, "-j", "MASQUERADE"))
	}
}

/* ---------- tap per VM ----------------------------------------------------- */

func createTap(name string) {
	must(exec.Command("ip", "tuntap", "add", name, "mode", "tap"))
	must(exec.Command("ip", "link", "set", name, "master", bridge))
	must(exec.Command("ip", "link", "set", name, "up"))
}

/* ---------- copy-on-write rootfs ------------------------------------------- */

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

/* ---------- spawn one VM --------------------------------------------------- */

func spawn(idx int, ip string) {
	vmID := "vm" + ip[len(ip)-2:]
	dir := filepath.Join("machine", vmID)
	_ = os.MkdirAll(dir, 0o755)

	vmRoot := filepath.Join(dir, "rootfs.ext4")
	if err := reflinkOrCopy(vmRoot, rootfs); err != nil {
		log.Fatalf("[%s] rootfs clone: %v", vmID, err)
	}

	tap := "tapfc" + ip[len(ip)-2:]
	createTap(tap)

	_, ipNet, _ := net.ParseCIDR(ip + "/24")

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

/* ---------- main ----------------------------------------------------------- */

func main() {
	ensureRoot()
	ensureBridge()

	spawn(0, "172.16.0.10")
	spawn(1, "172.16.0.11")
	spawn(2, "172.16.0.12")

	select {} // keep program alive
}
