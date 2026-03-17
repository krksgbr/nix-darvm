// dvm-vsock-bridge: guest-side vsock services for DVM.
//
// Two services run concurrently:
//
//  1. Nix daemon bridge: listens on a Unix socket, proxies each connection
//     to the host's nix daemon via AF_VSOCK (outbound, CID 2).
//
//  2. Control channel: listens on a vsock port for commands from the host
//     (inbound). Supports ACTIVATE <path> and STATUS.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

var startTime = time.Now()

func main() {
	listenPath := flag.String("listen", "/tmp/nix-daemon.sock", "Unix socket path to listen on")
	vsockPort := flag.Uint("vsock-port", 6174, "vsock port on the host to connect to")
	controlPort := flag.Uint("control-port", 6175, "vsock port to listen on for host control commands")
	flag.Parse()

	logEvent("", "info", "dvm-vsock-bridge starting")

	// Start control channel listener in background
	go listenControl(uint32(*controlPort))

	// Remove stale socket file
	os.Remove(*listenPath)

	ln, err := net.Listen("unix", *listenPath)
	if err != nil {
		logEvent("", "error", fmt.Sprintf("listen: %v", err))
		os.Exit(1)
	}
	defer ln.Close()

	// Make socket accessible to all users
	os.Chmod(*listenPath, 0666)

	logEvent("", "info", fmt.Sprintf("listening on %s, forwarding to vsock host:%d", *listenPath, *vsockPort))
	fmt.Printf("dvm-vsock-bridge: listening on %s, forwarding to vsock host:%d\n", *listenPath, *vsockPort)

	for {
		conn, err := ln.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "accept: %v\n", err)
			continue
		}
		go handleConn(conn, uint32(*vsockPort))
	}
}

// logEvent writes a structured JSON log entry to stderr.
func logEvent(phase, level, msg string) {
	entry := map[string]string{
		"t":     fmt.Sprintf("%.3f", time.Since(startTime).Seconds()),
		"level": level,
		"msg":   msg,
	}
	if phase != "" {
		entry["phase"] = phase
	}
	data, _ := json.Marshal(entry)
	fmt.Fprintf(os.Stderr, "%s\n", data)
}

// listenControl listens on a vsock port for control commands from the host.
func listenControl(port uint32) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		logEvent("", "error", fmt.Sprintf("control: socket: %v", err))
		return
	}

	err = unix.Bind(fd, &unix.SockaddrVM{
		CID:  unix.VMADDR_CID_ANY,
		Port: port,
	})
	if err != nil {
		unix.Close(fd)
		logEvent("", "error", fmt.Sprintf("control: bind: %v", err))
		return
	}

	err = unix.Listen(fd, 4)
	if err != nil {
		unix.Close(fd)
		logEvent("", "error", fmt.Sprintf("control: listen: %v", err))
		return
	}

	logEvent("", "info", fmt.Sprintf("control channel listening on vsock port %d", port))
	fmt.Printf("dvm-vsock-bridge: control channel listening on vsock port %d\n", port)

	for {
		connFD, _, err := unix.Accept(fd)
		if err != nil {
			logEvent("", "error", fmt.Sprintf("control: accept: %v", err))
			continue
		}
		logEvent("", "info", "control connection accepted")
		go handleControl(connFD)
	}
}

// handleControl processes a single control connection.
// Protocol: one command per line, one response per command.
//
//	ACTIVATE /nix/store/...  →  OK\n  or  ERR message\n
//	STATUS                   →  {"mounts":[...],...}\n
func handleControl(fd int) {
	f := os.NewFile(uintptr(fd), "vsock-control")
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.SplitN(line, " ", 2)
		cmd := parts[0]
		arg := ""
		if len(parts) > 1 {
			arg = parts[1]
		}

		switch cmd {
		case "ACTIVATE":
			if arg == "" {
				fmt.Fprintf(f, "ERR missing argument\n")
				continue
			}
			path := arg
			if !strings.HasPrefix(path, "/nix/store/") {
				fmt.Fprintf(f, "ERR invalid path: must start with /nix/store/\n")
				continue
			}
			logEvent("activating", "info", fmt.Sprintf("activating %s", path))
			activate := path + "/activate"
			execCmd := exec.Command("sudo", activate)
			execCmd.Stdout = os.Stdout
			execCmd.Stderr = os.Stderr
			err := execCmd.Run()
			if err != nil {
				logEvent("activating", "error", fmt.Sprintf("activation failed: %v", err))
				fmt.Fprintf(f, "ERR %v\n", err)
			} else {
				logEvent("activating", "info", "activation succeeded")
				fmt.Fprintf(f, "OK\n")
			}

		case "STATUS":
			logEvent("", "info", "STATUS command received")
			status := gatherStatus()
			data, err := json.Marshal(status)
			if err != nil {
				fmt.Fprintf(f, "ERR %v\n", err)
				continue
			}
			fmt.Fprintf(f, "%s\n", data)

		default:
			fmt.Fprintf(f, "ERR unknown command: %s\n", cmd)
		}
	}
}

// GuestStatus is the JSON payload returned by the STATUS command.
type GuestStatus struct {
	Mounts     []string          `json:"mounts"`
	Activation string            `json:"activation"`
	Services   map[string]string `json:"services"`
}

// gatherStatus collects current guest health information.
func gatherStatus() GuestStatus {
	return GuestStatus{
		Mounts:     gatherMounts(),
		Activation: gatherActivation(),
		Services:   gatherServices(),
	}
}

// gatherMounts parses /sbin/mount output for virtiofs mount points.
func gatherMounts() []string {
	out, err := exec.Command("/sbin/mount").Output()
	if err != nil {
		return nil
	}
	var mounts []string
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.Contains(line, "virtiofs") {
			continue
		}
		// Format: "tag on /mount/point (virtiofs, ...)"
		parts := strings.SplitN(line, " on ", 2)
		if len(parts) < 2 {
			continue
		}
		fields := strings.Fields(parts[1])
		if len(fields) > 0 {
			mounts = append(mounts, fields[0])
		}
	}
	return mounts
}

// gatherActivation reads the nix-darwin system profile symlink.
func gatherActivation() string {
	target, err := os.Readlink("/nix/var/nix/profiles/system")
	if err != nil {
		return "none"
	}
	return target
}

// gatherServices checks launchctl for DVM-related services.
func gatherServices() map[string]string {
	out, err := exec.Command("launchctl", "list").Output()
	if err != nil {
		return nil
	}
	services := make(map[string]string)
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.Contains(line, "dvm") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		name := fields[2]
		pid := fields[0]
		if pid == "-" {
			services[name] = "stopped"
		} else {
			services[name] = "running"
		}
	}
	return services
}

func handleConn(local net.Conn, port uint32) {
	defer local.Close()

	remoteFD, err := dialVsockHost(port)
	if err != nil {
		fmt.Fprintf(os.Stderr, "vsock dial: %v\n", err)
		return
	}

	remoteFile := os.NewFile(uintptr(remoteFD), "vsock")
	defer remoteFile.Close()

	var wg sync.WaitGroup
	wg.Add(2)

	// local (net.Conn) → remote (vsock fd)
	go func() {
		defer wg.Done()
		buf := make([]byte, 32768)
		for {
			n, err := local.Read(buf)
			if n > 0 {
				if _, werr := remoteFile.Write(buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()

	// remote (vsock fd) → local (net.Conn)
	go func() {
		defer wg.Done()
		buf := make([]byte, 32768)
		for {
			n, err := remoteFile.Read(buf)
			if n > 0 {
				if _, werr := local.Write(buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()

	wg.Wait()
}

// dialVsockHost connects to the host (CID 2) on the given vsock port.
// Returns the raw file descriptor.
func dialVsockHost(port uint32) (int, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		return -1, fmt.Errorf("socket: %w", err)
	}

	err = unix.Connect(fd, &unix.SockaddrVM{
		CID:  2, // VMADDR_CID_HOST
		Port: port,
	})
	if err != nil {
		unix.Close(fd)
		return -1, fmt.Errorf("connect: %w", err)
	}

	return fd, nil
}
