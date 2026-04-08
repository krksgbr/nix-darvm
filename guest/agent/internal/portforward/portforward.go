// Package portforward proxies host TCP connections to guest-local services via vsock.
//
// Listens on vsock port 6177. For each connection, reads a 2-byte big-endian
// target port header, dials 127.0.0.1:<port> locally, and proxies bidirectionally.
// Supports TCP half-close so clients can close their write side while still
// receiving a response.
package portforward

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
	"syscall"
	"time"

	"github.com/unbody/darvm/agent/internal/vsock"
	"golang.org/x/sys/unix"
)

const (
	vsockPort          = 6177
	headerSize         = 2
	headerTimeout      = 5 * time.Second
	copyDirectionCount = 2
)

// RunOnListener proxies connections from an already-bound listener to guest-local
// TCP services. The host writes a 2-byte big-endian target port, then data flows
// bidirectionally.
func RunOnListener(ctx context.Context, ln net.Listener) error {
	log.Printf("port forward proxy listening on vsock port %d", vsockPort)

	go func() {
		<-ctx.Done()
		closeListener(ln)
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return fmt.Errorf("port forward context cancelled: %w", ctx.Err())
			default:
				log.Printf("port forward accept: %v", err)

				continue
			}
		}

		go handleConn(ctx, conn)
	}
}

// Run listens on vsock port 6177 and proxies connections to guest-local TCP services.
func Run(ctx context.Context) error {
	ln, err := vsock.Listen(vsockPort)
	if err != nil {
		return fmt.Errorf("port forward listen: %w", err)
	}
	defer closeListener(ln)

	return RunOnListener(ctx, ln)
}

func handleConn(ctx context.Context, vsockConn net.Conn) {
	defer closeConn(vsockConn)

	// Read 2-byte target port with timeout to prevent hung connections.
	if err := vsockConn.SetReadDeadline(time.Now().Add(headerTimeout)); err != nil {
		if !errors.Is(err, os.ErrNoDeadline) {
			log.Printf("port forward set header deadline: %v", err)
		}
	}

	var headerBuf [headerSize]byte

	if _, err := io.ReadFull(vsockConn, headerBuf[:]); err != nil {
		log.Printf("port forward read header: %v", err)

		return
	}

	targetPort := binary.BigEndian.Uint16(headerBuf[:])
	if targetPort == 0 {
		log.Printf("port forward: rejecting target port 0")

		return
	}

	// Clear the deadline for the proxy phase.
	if err := vsockConn.SetReadDeadline(time.Time{}); err != nil {
		if !errors.Is(err, os.ErrNoDeadline) {
			log.Printf("port forward clear deadline: %v", err)
		}
	}

	tcpConn, err := (&net.Dialer{}).DialContext(ctx, "tcp", fmt.Sprintf("127.0.0.1:%d", targetPort))
	if err != nil {
		log.Printf("port forward dial 127.0.0.1:%d: %v", targetPort, err)

		return
	}
	defer closeConn(tcpConn)

	proxy(vsockConn, tcpConn)
}

// proxy copies data bidirectionally with proper TCP half-close semantics.
// When one direction finishes, it shuts down the write side of the destination
// (not full close) so the other direction can still drain.
func proxy(vsockConn net.Conn, tcpConn net.Conn) {
	var wg sync.WaitGroup
	wg.Add(copyDirectionCount)

	// vsock → tcp: host is sending data to the guest service.
	go func() {
		defer wg.Done()

		if _, err := io.Copy(tcpConn, vsockConn); err != nil {
			log.Printf("port forward copy vsock->tcp: %v", err)
		}

		// Half-close: signal TCP EOF without tearing down the connection.
		if tc, ok := tcpConn.(*net.TCPConn); ok {
			if err := tc.CloseWrite(); err != nil {
				log.Printf("port forward tcp CloseWrite: %v", err)
			}
		}
	}()

	// tcp → vsock: guest service is sending data back to the host.
	go func() {
		defer wg.Done()

		if _, err := io.Copy(vsockConn, tcpConn); err != nil {
			log.Printf("port forward copy tcp->vsock: %v", err)
		}

		// Half-close: signal vsock EOF without tearing down the connection.
		shutdownVsockWrite(vsockConn)
	}()

	wg.Wait()
}

// shutdownVsockWrite sends a write-side shutdown on the vsock connection.
// Uses the syscall.Conn interface exposed by the vsock conn type.
func shutdownVsockWrite(conn net.Conn) {
	sc, ok := conn.(syscall.Conn)
	if !ok {
		return
	}

	raw, err := sc.SyscallConn()
	if err != nil {
		log.Printf("port forward vsock SyscallConn: %v", err)

		return
	}

	var shutdownErr error

	if err := raw.Control(func(fd uintptr) {
		shutdownErr = unix.Shutdown(int(fd), unix.SHUT_WR) //nolint:gosec // G115: file descriptors fit in int
	}); err != nil {
		log.Printf("port forward vsock Control: %v", err)

		return
	}

	if shutdownErr != nil {
		log.Printf("port forward vsock SHUT_WR: %v", shutdownErr)
	}
}

func closeListener(ln net.Listener) {
	if err := ln.Close(); err != nil {
		log.Printf("port forward listener close: %v", err)
	}
}

func closeConn(conn net.Conn) {
	if err := conn.Close(); err != nil {
		log.Printf("port forward conn close: %v", err)
	}
}
