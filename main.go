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
	kernel   = "machines/build/downloads/hello-vmlinux.bin"
	rootfs   = "machines/build/alpine-rootfs.ext4"
	bridge   = "fcbr0"
	hostCIDR = "172.16.0.1/24"
	hostGW   = "172.16.0.1"
	subnet   = "172.16.0.0/24"
	memMB    = 512
)

// run executes a command and logs fatal on error.
func run(cmd ...string) {
	c := exec.Command(cmd[0], cmd[1:]...)
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		log.Fatalf("cmd %v: %v", cmd, err)
	}
}

func cleanupStaleTap() {
	cmds := [][]string{
		{"ip", "link", "delete", "tapfc0"},
		{"ip", "route", "del", "172.16.0.0/24", "dev", "tapfc0"},
		{"ip", "neigh", "flush", "dev", "tapfc0"},
	}
	for _, args := range cmds {
		// ignore errors, we just want to clear any leftover config
		exec.Command(args[0], args[1:]...).Run()
	}
}

// ensureRoot makes sure the program is run as root.
func ensureRoot() {
	if os.Geteuid() != 0 {
		log.Fatal("run with sudo")
	}
}

// bridgeUp creates and configures the bridge if not present.
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

// mkTap creates a tap device and attaches it to the bridge.
func mkTap(name string) {
	_ = exec.Command("ip", "link", "del", name).Run()
	run("ip", "tuntap", "add", name, "mode", "tap")
	run("ip", "link", "set", name, "master", bridge)
	run("ip", "link", "set", name, "up")
}

// reflinkOrCopy tries a reflink clone, falling back to copy.
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

// spawn attempts to configure and start a VM at the given IP.
// On success, returns nil; on failure, returns an error.
func spawn(ip string) error {
	sfx := ip[strings.LastIndex(ip, ".")+1:]
	vmID := "vm" + sfx
	dir := filepath.Join("machines", "machine", vmID)
	os.RemoveAll(dir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("failed to create dir %s: %w", dir, err)
	}

	// copy or reflink rootfs
	dst := filepath.Join(dir, "rootfs.ext4")
	if err := reflinkOrCopy(dst, rootfs); err != nil {
		return fmt.Errorf("[%s] rootfs copy: %w", vmID, err)
	}

	// create tap
	tap := "tapfc" + sfx
	mkTap(tap)

	// kernel args
	kargs := fmt.Sprintf(
		"console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw ip=%s::%s:255.255.255.0::eth0:off",
		ip, hostGW)

	// Firecracker config
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

	// create and start the machine
	m, err := fc.NewMachine(context.Background(), cfg)
	if err != nil {
		return fmt.Errorf("[%s] new: %w", vmID, err)
	}
	if err := m.Start(context.Background()); err != nil {
		return fmt.Errorf("[%s] start: %w", vmID, err)
	}

	// log and wait
	log.Printf("[%s] up → ssh root@%s (pwd firecracker)", vmID, ip)
	go m.Wait(context.Background())

	return nil
}

func main() {
	cleanupStaleTap()
	ensureRoot()
	bridgeUp()

	ips := []string{"172.16.0.10", "172.16.0.11", "172.16.0.12"}
	var success []string
	var failed []string

	for _, ip := range ips {
		if err := spawn(ip); err != nil {
			log.Printf("ERROR %s: %v", ip, err)
			failed = append(failed, ip)
		} else {
			success = append(success, ip)
		}
	}

	// summary
	fmt.Println("\n=== Summary ===")
	if len(success) > 0 {
		fmt.Printf("Running VMs:\n")
		for _, ip := range success {
			fmt.Printf("  %s → ssh root@%s (pwd firecracker)\n", ip, ip)
		}
	} else {
		fmt.Println("No VMs started successfully.")
	}
	if len(failed) > 0 {
		fmt.Printf("Failed VMs:\n")
		for _, ip := range failed {
			fmt.Printf("  %s\n", ip)
		}
	}

	// block forever
	select {}
}
