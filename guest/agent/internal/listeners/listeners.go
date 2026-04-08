// Package listeners discovers TCP sockets in LISTEN state on loopback interfaces.
package listeners

import (
	"context"
	"log"
	"os/exec"
	"slices"
	"strconv"
	"strings"
)

// Scan runs lsof to discover TCP ports listening on loopback interfaces.
// Returns a deduplicated, sorted list of ports. Returns nil on error.
func Scan(ctx context.Context) []uint16 {
	out, err := exec.CommandContext(ctx, "/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN").Output()
	if err != nil {
		log.Printf("listeners: lsof: %v", err)

		return nil
	}

	return ParseLsofOutput(string(out))
}

// ParseLsofOutput extracts loopback listening ports from lsof -nP -iTCP -sTCP:LISTEN output.
// Keeps ports bound to 127.0.0.1, [::1], or * (wildcard includes loopback).
// Returns a deduplicated, sorted list.
func ParseLsofOutput(output string) []uint16 {
	seen := make(map[uint16]struct{})

	for line := range strings.SplitSeq(output, "\n") {
		if !strings.Contains(line, "(LISTEN)") {
			continue
		}

		port, ok := parseListenLine(line)
		if !ok || port == 0 {
			continue
		}

		seen[port] = struct{}{}
	}

	if len(seen) == 0 {
		return nil
	}

	ports := make([]uint16, 0, len(seen))
	for p := range seen {
		ports = append(ports, p)
	}

	slices.Sort(ports)

	return ports
}

// parseListenLine extracts the port from a single lsof output line.
// Returns the port and true if the line is a loopback (or wildcard) listener.
//
// Lines look like:
//
//	node  12345 user  4u  IPv4 0x... TCP 127.0.0.1:8080 (LISTEN)
//	node  12345 user  4u  IPv6 0x... TCP [::1]:3000 (LISTEN)
//	node  12345 user  4u  IPv4 0x... TCP *:5000 (LISTEN)
func parseListenLine(line string) (uint16, bool) {
	// Find the field just before (LISTEN), which contains the address:port.
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return 0, false
	}

	// The NAME column is the second-to-last field (last is "(LISTEN)").
	nameField := fields[len(fields)-2]

	// Split address and port on the last colon.
	lastColon := strings.LastIndex(nameField, ":")
	if lastColon < 0 || lastColon == len(nameField)-1 {
		return 0, false
	}

	addr := nameField[:lastColon]
	portStr := nameField[lastColon+1:]

	// Only keep loopback and wildcard listeners.
	if !isLoopbackOrWildcard(addr) {
		return 0, false
	}

	portVal, err := strconv.ParseUint(portStr, 10, 16)
	if err != nil {
		return 0, false
	}

	return uint16(portVal), true
}

func isLoopbackOrWildcard(addr string) bool {
	switch addr {
	case "127.0.0.1", "[::1]", "*":
		return true
	default:
		return false
	}
}
