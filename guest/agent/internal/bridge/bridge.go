// Package bridge proxies guest nix daemon connections to the host via vsock.
//
// Listens on a Unix socket (/tmp/nix-daemon.sock). For each client connection,
// dials the host via AF_VSOCK (CID 2, port 6174) and proxies bidirectionally.
package bridge

import (
	"context"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"os"
	"sync"

	"golang.org/x/sys/unix"
)

const (
	defaultListenPath = "/tmp/nix-daemon.sock"
	defaultVsockPort  = 6174
	hostCID           = 2 // VMADDR_CID_HOST
	bufSize           = 32768
)

type Bridge struct {
	ListenPath string
	VsockPort  uint32
}

func New() *Bridge {
	return &Bridge{
		ListenPath: defaultListenPath,
		VsockPort:  defaultVsockPort,
	}
}

func (b *Bridge) Run(ctx context.Context) error {
	if err := os.Remove(b.ListenPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove stale bridge socket: %w", err)
	}

	ln, err := (&net.ListenConfig{}).Listen(ctx, "unix", b.ListenPath)
	if err != nil {
		return fmt.Errorf("bridge listen: %w", err)
	}
	defer closeListener(ln)

	if err := os.Chmod(b.ListenPath, 0666); err != nil { //nolint:gosec // Guest user processes must reach the bridge socket without elevating to root.
		return fmt.Errorf("chmod bridge socket: %w", err)
	}

	log.Printf("nix daemon bridge listening on %s, forwarding to vsock host:%d", b.ListenPath, b.VsockPort)

	// Close listener when context is cancelled
	go func() {
		<-ctx.Done()
		closeListener(ln)
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return fmt.Errorf("bridge context cancelled: %w", ctx.Err())
			default:
				log.Printf("bridge accept: %v", err)

				continue
			}
		}

		go b.handleConn(conn)
	}
}

func (b *Bridge) handleConn(local net.Conn) {
	defer closeConn(local)

	remoteFD, err := dialVsockHost(b.VsockPort)
	if err != nil {
		log.Printf("bridge vsock dial: %v", err)

		return
	}

	remoteFDValue, err := nonNegativeIntToUintptr(remoteFD)
	if err != nil {
		log.Printf("bridge invalid vsock fd %d: %v", remoteFD, err)

		if closeErr := unix.Close(remoteFD); closeErr != nil {
			log.Printf("bridge close invalid vsock fd=%d: %v", remoteFD, closeErr)
		}

		return
	}

	remote := os.NewFile(remoteFDValue, "vsock")
	defer closeFile(remote)

	var wg sync.WaitGroup
	wg.Add(2)

	// local → remote. When this direction closes, close remote to unblock
	// the remote → local goroutine (which may be blocked on remote.Read).
	go func() {
		defer wg.Done()

		if _, err := io.Copy(remote, local); err != nil {
			log.Printf("bridge copy local->remote: %v", err)
		}

		closeFile(remote)
	}()

	// remote → local. When this direction closes, close local to unblock
	// the local → remote goroutine (which may be blocked on local.Read).
	go func() {
		defer wg.Done()

		if _, err := io.Copy(local, remote); err != nil {
			log.Printf("bridge copy remote->local: %v", err)
		}

		closeConn(local)
	}()

	wg.Wait()
}

func dialVsockHost(port uint32) (int, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		return -1, fmt.Errorf("socket: %w", err)
	}

	err = unix.Connect(fd, &unix.SockaddrVM{
		CID:  hostCID,
		Port: port,
	})
	if err != nil {
		if closeErr := unix.Close(fd); closeErr != nil {
			log.Printf("bridge close failed socket fd=%d: %v", fd, closeErr)
		}

		return -1, fmt.Errorf("connect: %w", err)
	}

	return fd, nil
}

func nonNegativeIntToUintptr(v int) (uintptr, error) {
	if v < 0 {
		return 0, fmt.Errorf("negative value %d", v)
	}

	if uint64(v) > math.MaxUint {
		return 0, fmt.Errorf("value %d exceeds uintptr range", v)
	}

	return uintptr(v), nil
}

func closeListener(listener net.Listener) {
	if err := listener.Close(); err != nil {
		log.Printf("bridge listener close: %v", err)
	}
}

func closeConn(conn net.Conn) {
	if err := conn.Close(); err != nil {
		log.Printf("bridge conn close: %v", err)
	}
}

func closeFile(file *os.File) {
	if err := file.Close(); err != nil {
		log.Printf("bridge file close: %v", err)
	}
}
