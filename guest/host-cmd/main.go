// dvm-host-cmd forwards host actions from the guest VM to the host over vsock.
//
// Busybox pattern: when invoked via a symlink (e.g. /run/current-system/sw/bin/notify),
// argv[0] determines the action name. When invoked directly, argv[1] is the
// action: dvm-host-cmd notify "message".
//
// Protocol: action_name\npayload over vsock to host port 6176.
//
//	Action name on first line, remaining args as NUL-separated payload.
//	Guest shuts down write end to signal EOF.
//
// Response: "<exit_code>\n" or "<exit_code>\x00<error>\n".
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

const (
	hostCID      = 2    // VMADDR_CID_HOST
	vsockPort    = 6176 // HostCommandBridge listen port
	maxRespBytes = 4096
)

func main() {
	cmd, args := resolveCommand(os.Args)
	if cmd == "" {
		fmt.Fprintf(os.Stderr, "usage: dvm-host-cmd <command> [args...]\n")
		os.Exit(1)
	}

	exitCode, err := execOnHost(cmd, args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dvm-host-cmd: %v\n", err)
		os.Exit(1)
	}
	os.Exit(exitCode)
}

// resolveCommand determines the command name and args from argv.
// Busybox mode: argv[0] is a symlink name (e.g. "notify").
// Direct mode: argv[1] is the command (e.g. "dvm-host-cmd notify msg").
func resolveCommand(argv []string) (string, []string) {
	base := filepath.Base(argv[0])
	if base != "dvm-host-cmd" {
		return base, argv[1:]
	}
	if len(argv) < 2 {
		return "", nil
	}
	return argv[1], argv[2:]
}

func execOnHost(cmd string, args []string) (int, error) {
	fd, err := dialVsock(hostCID, vsockPort)
	if err != nil {
		return 1, fmt.Errorf("connect to host: %w", err)
	}
	defer unix.Close(fd)

	// Build request: action name on first line, args as NUL-separated payload
	request := cmd + "\n"
	if len(args) > 0 {
		request += strings.Join(args, "\x00")
	}
	if _, err := unix.Write(fd, []byte(request)); err != nil {
		return 1, fmt.Errorf("send command: %w", err)
	}
	// Signal we're done writing
	unix.Shutdown(fd, unix.SHUT_WR)

	// Read response
	resp, err := readResponse(fd)
	if err != nil {
		return 1, fmt.Errorf("read response: %w", err)
	}

	return parseResponse(resp)
}

func dialVsock(cid uint32, port uint32) (int, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		return -1, fmt.Errorf("socket: %w", err)
	}

	err = unix.Connect(fd, &unix.SockaddrVM{
		CID:  cid,
		Port: port,
	})
	if err != nil {
		unix.Close(fd)
		return -1, fmt.Errorf("connect: %w", err)
	}

	return fd, nil
}

func readResponse(fd int) (string, error) {
	var buf [maxRespBytes]byte
	total := 0
	for total < maxRespBytes {
		n, err := unix.Read(fd, buf[total:])
		if n > 0 {
			total += n
		}
		if err != nil {
			break
		}
		if n == 0 {
			break // EOF
		}
	}
	if total == 0 {
		return "", fmt.Errorf("empty response from host")
	}
	return string(buf[:total]), nil
}

func parseResponse(resp string) (int, error) {
	resp = strings.TrimRight(resp, "\n")
	if resp == "" {
		return 1, fmt.Errorf("empty response from host")
	}

	// Format: "<exit_code>" or "<exit_code>\x00<error>"
	parts := strings.SplitN(resp, "\x00", 2)
	code, err := strconv.Atoi(parts[0])
	if err != nil {
		return 1, fmt.Errorf("invalid exit code: %q", parts[0])
	}

	if len(parts) > 1 && parts[1] != "" {
		fmt.Fprintf(os.Stderr, "dvm-host-cmd: %s\n", parts[1])
	}

	return code, nil
}
