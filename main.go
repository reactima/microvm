// main.go – starts 3 microVMs (vm10..12) using Firecracker
// Run as root:   sudo -E $(which go) run main.go
package main

import (
	"context"
	"fmt"
	fc "github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"golang.org/x/sys/unix"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	kernel     = "hello-vmlinux.bin"
	rootfs     = "alpine-rootfs.ext4"
	bridge     = "fcbr0"
	hostCIDR   = "172.16.0.1/24"
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

func run(cmd ...string) { must(exec.Command(cmd[0], cmd[1:]...)) }

/* ---------- root check & bridge ------------------------------------------- */

func ensureRoot() {
	if os.Geteuid() != 0 {
		log.Fatal("Run with: sudo -E $(which go) run main.go")
	}
}

func ensureBridge() {
	if _, err := os.Stat("/sys/class/net/" + bridge); os.IsNotExist(err) {
		run("ip", "link", "add", bridge, "type", "bridge")
		run("ip", "addr", "add", hostCIDR, "dev", bridge)
		run("ip", "link", "set", bridge, "up")
	}
	if exec.Command("iptables", "-t", "nat", "-C", "POSTROUTING",
		"-s", subnetCIDR, "-j", "MASQUERADE").Run() != nil {
		run("iptables", "-t", "nat", "-A", "POSTROUTING",
			"-s", subnetCIDR, "-j", "MASQUERADE")
	}
}

/* ---------- tap helpers ---------------------------------------------------- */

func cleanTap(name string) {
	_ = exec.Command("ip", "link", "del", name).Run()
}

func newTapSuffix(base string) string {
	for i := 10; i < 100; i++ {
		name := fmt.Sprintf("%s%d", base, i)
		if _, err := os.Stat("/sys/class/net/" + name); os.IsNotExist(err) {
			return name
		}
	}
	log.Fatalf("ran out of tap names")
	return ""
}

func createTap(name string) {
	cleanTap(name) // delete stale one
	run("ip", "tuntap", "add", name, "mode", "tap")
	run("ip", "link", "set", name, "master", bridge)
	run("ip", "link", "set", name, "up")
}

/* ---------- rootfs clone --------------------------------------------------- */

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

/* ---------- spawn VM ------------------------------------------------------- */

func spawn(idx int, ip string) {
	vmID := "vm" + ip[strings.LastIndex(ip, ".")+1:]
	dir := filepath.Join("machine", vmID)
	_ = os.MkdirAll(dir, 0o755)

	vmRoot := filepath.Join(dir, "rootfs.ext4")
	if err := reflinkOrCopy(vmRoot, rootfs); err != nil {
		log.Fatalf("[%s] rootfs clone: %v", vmID, err)
	}

	tap := "tapfc" + ip[strings.LastIndex(ip, ".")+1:]
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
		// tap busy? pick next name & recurse once
		if strings.Contains(err.Error(), "Device or resource busy") {
			nextTap := newTapSuffix("tapfc")
			log.Printf("[%s] %s busy, retrying with %s", vmID, tap, nextTap)
			cleanTap(nextTap)
			createTap(nextTap)
			cfg.NetworkInterfaces[0].StaticConfiguration.HostDevName = nextTap
			if err := m.Start(context.Background()); err != nil {
				log.Fatalf("[%s] start (retry): %v", vmID, err)
			}
		} else {
			log.Fatalf("[%s] start: %v", vmID, err)
		}
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
