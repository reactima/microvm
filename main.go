// main.go – 3-VM launcher with resource-exhaustion checks
package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	fc "github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
	"github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
)

const (
	kernel     = "hello-vmlinux.bin"
	rootfs     = "alpine-rootfs.ext4"
	hostGW     = "172.16.0.1"
	memPerVMMB = 96 // must match MachineCfg below
)

var log = logrus.New()

/* ---------------------------------------------------- helpers  */

func must(cmd *exec.Cmd) {
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		panic(err)
	}
}

// memOK returns true when MemAvailable in /proc/meminfo ≥ needMB.
func memOK(needMB int) bool {
	f, _ := os.Open("/proc/meminfo")
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if strings.HasPrefix(sc.Text(), "MemAvailable:") {
			fields := strings.Fields(sc.Text())
			kib, _ := strconv.Atoi(fields[1])
			return kib/1024 >= needMB
		}
	}
	return true // fallback: assume OK
}

// diskOK checks free space under dir ≥ needMB.
func diskOK(dir string, needMB int) bool {
	var st unix.Statfs_t
	if err := unix.Statfs(dir, &st); err != nil {
		return true // best effort
	}
	free := st.Bavail * uint64(st.Bsize) / (1024 * 1024)
	return int(free) >= needMB
}

/* --------------------------------------------- tap management  */

// freeTap returns a tap name that doesn’t exist OR is not open by any process.
func freeTap(base string, idx int) string {
	for {
		name := fmt.Sprintf("%s%d", base, idx)
		if _, err := os.Stat("/sys/class/net/" + name); os.IsNotExist(err) {
			return name // brand-new
		}
		// Is the tap in use by another FD?  Check lsof – quicker via fuser -v.
		out, _ := exec.Command("fuser", "-v", "/dev/net/tun").CombinedOutput()
		if !bytes.Contains(out, []byte(name)) {
			// tap exists but no one holds it: delete & reuse
			_ = exec.Command("sudo", "ip", "link", "del", name).Run()
			return name
		}
		idx++ // else busy → pick next suffix
	}
}

// createTap creates/sets-up the tap. idx==0 gets addr & MASQUERADE.
func createTap(tap string, idx int) {
	must(exec.Command("sudo", "ip", "tuntap", "add", "dev", tap, "mode", "tap"))
	if idx == 0 {
		must(exec.Command("sudo", "ip", "addr", "add", hostGW+"/24", "dev", tap))
		// add MASQUERADE rule only once
		if err := exec.Command("sudo", "iptables", "-C", "POSTROUTING", "-t", "nat",
			"-s", "172.16.0.0/24", "-j", "MASQUERADE").Run(); err != nil {
			must(exec.Command("sudo", "iptables", "-A", "POSTROUTING", "-t", "nat",
				"-s", "172.16.0.0/24", "-j", "MASQUERADE"))
		}
	}
	must(exec.Command("sudo", "ip", "link", "set", tap, "up"))
}

/* ------------------------------------------- rootfs per-VM CoW */

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
	if err := unix.IoctlSetInt(int(out.Fd()), ficlone, int(in.Fd())); err == nil {
		return nil
	}
	_, err = io.Copy(out, in)
	return err
}

/* --------------------------------------------------- VM spawn  */

func spawn(idx int, ip string) {
	vmID := fmt.Sprintf("vm%d", idx)

	if !memOK(memPerVMMB) {
		log.Fatalf("[%s] host RAM exhausted (need %d MiB free)", vmID, memPerVMMB)
	}
	if !diskOK(".", 50) { // need ~50 MB free with copy path
		log.Fatalf("[%s] host disk space exhausted (<50 MiB free)", vmID)
	}

	dir := filepath.Join("machine", vmID)
	_ = os.MkdirAll(dir, 0o755)

	vmRoot := filepath.Join(dir, "rootfs.ext4")
	if err := reflinkOrCopy(vmRoot, rootfs); err != nil {
		log.Fatalf("[%s] rootfs clone: %v", vmID, err)
	}

	tap := freeTap("tapfc", idx)
	createTap(tap, idx)

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
				MacAddress:  fmt.Sprintf("AA:FC:00:%02d:%02d:%02d", idx, idx, idx),
				IPConfiguration: &fc.IPConfiguration{
					IPAddr:  *ipNet,
					Gateway: net.ParseIP(hostGW),
				},
			},
		}},
		MachineCfg: models.MachineConfiguration{
			MemSizeMib: fc.Int64(memPerVMMB),
			VcpuCount:  fc.Int64(1),
		},
		VMID: vmID,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	entry := log.WithField("vm", vmID)
	m, err := fc.NewMachine(ctx, cfg, fc.WithLogger(entry))
	if err != nil {
		entry.Fatalf("new: %v", err)
	}
	if err := m.Start(ctx); err != nil {
		entry.Fatalf("start: %v", err)
	}
	entry.Infof("up → ssh root@%s (pwd firecracker)  |  tap=%s", ip, tap)
	go m.Wait(context.Background())
}

/* -------------------------------------------------------------- */

func main() {
	log.SetFormatter(&logrus.TextFormatter{FullTimestamp: true})

	spawn(0, "172.16.0.10")
	spawn(1, "172.16.0.11")
	spawn(2, "172.16.0.12")

	select {} // keep host alive
}
