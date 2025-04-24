package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"

	firecracker "github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
)

func must(cmd *exec.Cmd) {
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatal(err)
	}
}

func main() {
	const (
		workDir    = "machine"
		kernel     = "hello-vmlinux.bin"
		rootfs     = "hello-rootfs.ext4"
		tapDev     = "tap0"
		hostIP     = "172.16.0.1/24"
		guestIP    = "172.16.0.2"
		serialSock = workDir + "/serial.sock"
	)

	// --- host networking (idempotent) ----------------------------------------
	if _, err := os.Stat("/sys/class/net/" + tapDev); os.IsNotExist(err) {
		fmt.Println("🔌 Creating tap interface …")
		must(exec.Command("sudo", "ip", "tuntap", "add", "dev", tapDev, "mode", "tap", "user", os.Getenv("USER")))
		must(exec.Command("sudo", "ip", "addr", "add", hostIP, "dev", tapDev))
		must(exec.Command("sudo", "ip", "link", "set", tapDev, "up"))
		must(exec.Command("sudo", "sysctl", "-w", "net.ipv4.ip_forward=1"))
	}

	// --- firecracker config ---------------------------------------------------
	cfg := firecracker.Config{
		SocketPath:      workDir + "/fc.sock",
		LogFifo:         workDir + "/fc.logfifo",
		MetricsFifo:     workDir + "/fc.metricsfifo",
		KernelImagePath: kernel,
		KernelArgs: fmt.Sprintf(
			"console=ttyS0 reboot=k panic=1 pci=off ip=%s::%s:255.255.255.0::eth0:off root=/dev/vda rw",
			guestIP, hostIP[:len(hostIP)-3]), // strip /24
		Drives: []models.Drive{
			{
				DriveID:      firecracker.String("rootfs"),
				PathOnHost:   firecracker.String(rootfs),
				IsRootDevice: firecracker.Bool(true),
				IsReadOnly:   firecracker.Bool(false),
			},
		},
		MachineCfg: models.MachineConfiguration{
			VCpus:      1,
			MemSizeMib: 512,
		},
		NetworkInterfaces: []firecracker.NetworkInterface{
			{
				StaticConfiguration: &firecracker.StaticNetworkConfiguration{
					HostDevName: tapDev,
					MacAddress:  "AA:FC:00:00:00:01",
					IPConfiguration: &firecracker.IPConfiguration{
						IPAddr:  guestIP + "/24",
						Gateway: hostIP[:len(hostIP)-3],
					},
				},
			},
		},
		SerialConsolePath: serialSock, // ⬅ Firecracker-go-sdk >= v0.27
		Debug:             true,
	}

	if err := os.MkdirAll(workDir, 0755); err != nil {
		log.Fatalf("creating %s: %v", workDir, err)
	}

	// start VM
	ctx := context.Background()
	m, err := firecracker.NewMachine(ctx, cfg)
	if err != nil {
		log.Fatalf("new machine: %v", err)
	}

	if err := m.Start(ctx); err != nil {
		log.Fatalf("start: %v", err)
	}
	log.Println("✅ microVM running — try: ssh root@" + guestIP)
	if err := m.Wait(ctx); err != nil {
		log.Fatalf("wait: %v", err)
	}
}
