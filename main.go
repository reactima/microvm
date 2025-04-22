package main

import (
	"context"
	"log"
	"os"
	"time"

	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
)

func main() {
	workDir := "machine"
	socketPath := workDir + "/fc.sock"

	ctx := context.Background()

	cfg := firecracker.Config{
		SocketPath:      socketPath,
		LogFifo:         workDir + "/fc-logs.fifo",
		MetricsFifo:     workDir + "/fc-logs.fifo",
		KernelImagePath: "vmlinux.bin",
		KernelArgs:      "console=ttyS0 reboot=k panic=1 pci=off",
		Drives: []models.Drive{
			{
				DriveID:      firecracker.String("rootfs"),
				PathOnHost:   firecracker.String("rootfs.ext4"),
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
					HostDevName: "tap0",
					MacAddress:  "AA:FC:00:00:00:01",
				},
			},
		},
		Debug: true,
	}

	if err := os.MkdirAll(workDir, 0755); err != nil {
		log.Fatalf("creating %s: %v", workDir, err)
	}

	machine, err := firecracker.NewMachine(ctx, cfg)
	if err != nil {
		log.Fatalf("NewMachine failed: %v", err)
	}

	if err := machine.Start(ctx); err != nil {
		log.Fatalf("Start failed: %v", err)
	}
	log.Println("VM started; running for 10s then stopping")

	time.Sleep(10 * time.Second)

	if err := machine.StopVMM(); err != nil {
		log.Fatalf("StopVMM failed: %v", err)
	}
	if err := machine.Wait(ctx); err != nil {
		log.Fatalf("Wait failed: %v", err)
	}
	log.Println("VM stopped cleanly")
}
