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
	os.Remove(b.ListenPath)

	ln, err := net.Listen("unix", b.ListenPath)
	if err != nil {
		return fmt.Errorf("bridge listen: %w", err)
	}
	defer ln.Close()

	os.Chmod(b.ListenPath, 0666)

	log.Printf("nix daemon bridge listening on %s, forwarding to vsock host:%d", b.ListenPath, b.VsockPort)

	// Close listener when context is cancelled
	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			default:
				log.Printf("bridge accept: %v", err)
				continue
			}
		}
		go b.handleConn(conn)
	}
}

func (b *Bridge) handleConn(local net.Conn) {
	defer local.Close()

	remoteFD, err := dialVsockHost(b.VsockPort)
	if err != nil {
		log.Printf("bridge vsock dial: %v", err)
		return
	}

	remote := os.NewFile(uintptr(remoteFD), "vsock")
	defer remote.Close()

	var wg sync.WaitGroup
	wg.Add(2)

	// local → remote. When this direction closes, close remote to unblock
	// the remote → local goroutine (which may be blocked on remote.Read).
	go func() {
		defer wg.Done()
		io.Copy(remote, local)
		remote.Close()
	}()

	// remote → local. When this direction closes, close local to unblock
	// the local → remote goroutine (which may be blocked on local.Read).
	go func() {
		defer wg.Done()
		io.Copy(local, remote)
		local.Close()
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
		unix.Close(fd)
		return -1, fmt.Errorf("connect: %w", err)
	}

	return fd, nil
}
