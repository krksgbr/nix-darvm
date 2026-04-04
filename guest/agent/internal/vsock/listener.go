package vsock

import (
	"errors"
	"fmt"
	"log"
	"net"
	"os"

	"golang.org/x/sys/unix"
)

var errNonVSockPeer = errors.New("accepted a non-AF_VSOCK connection on an AF_VSOCK socket")

type listener struct {
	file *os.File
	port uint32
}

func Listen(port uint32) (net.Listener, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("create vsock listener socket on port %d: %w", port, err)
	}

	if err := unix.SetNonblock(fd, true); err != nil {
		if closeErr := unix.Close(fd); closeErr != nil {
			log.Printf("vsock: close listener fd=%d after SetNonblock failure: %v", fd, closeErr)
		}

		return nil, fmt.Errorf("set vsock listener nonblocking on port %d: %w", port, err)
	}

	file := os.NewFile(uintptr(fd), "vsock")

	if err := unix.Bind(int(file.Fd()), &unix.SockaddrVM{
		CID:  unix.VMADDR_CID_ANY,
		Port: port,
	}); err != nil {
		if closeErr := file.Close(); closeErr != nil {
			log.Printf("vsock: close listener file after bind failure on port %d: %v", port, closeErr)
		}

		return nil, fmt.Errorf("bind vsock listener on port %d: %w", port, err)
	}

	if err := unix.Listen(int(file.Fd()), unix.SOMAXCONN); err != nil {
		if closeErr := file.Close(); closeErr != nil {
			log.Printf("vsock: close listener file after listen failure on port %d: %v", port, closeErr)
		}

		return nil, fmt.Errorf("listen on vsock port %d: %w", port, err)
	}

	return &listener{
		file: file,
		port: port,
	}, nil
}

func (listener *listener) Accept() (net.Conn, error) {
	fd, _, err := unix.Accept(int(listener.file.Fd()))
	if err != nil {
		return nil, fmt.Errorf("accept vsock connection on port %d: %w", listener.port, err)
	}

	if err := unix.SetNonblock(fd, true); err != nil {
		if closeErr := unix.Close(fd); closeErr != nil {
			log.Printf("vsock: close accepted fd=%d after SetNonblock failure: %v", fd, closeErr)
		}

		return nil, fmt.Errorf("set accepted vsock connection nonblocking on port %d: %w", listener.port, err)
	}

	file := os.NewFile(uintptr(fd), "vsock")

	peerName, err := unix.Getpeername(int(file.Fd()))
	if err != nil {
		if closeErr := file.Close(); closeErr != nil {
			log.Printf("vsock: close accepted file after Getpeername failure on port %d: %v", listener.port, closeErr)
		}

		return nil, fmt.Errorf("failed to get peer name for AF_VSOCK connection: %w", err)
	}

	peerNameVM, ok := peerName.(*unix.SockaddrVM)
	if !ok {
		if closeErr := file.Close(); closeErr != nil {
			log.Printf("vsock: close accepted file after non-vsock peer on port %d: %v", listener.port, closeErr)
		}

		return nil, errNonVSockPeer
	}

	log.Printf("vsock: accepted connection on port %d from CID %d port %d (fd=%d)",
		listener.port, peerNameVM.CID, peerNameVM.Port, fd)

	return &conn{
		file:       file,
		localPort:  listener.port,
		remotePort: peerNameVM.Port,
	}, nil
}

func (listener *listener) Addr() net.Addr {
	return &addr{port: listener.port}
}

func (listener *listener) Close() error {
	if err := listener.file.Close(); err != nil {
		return fmt.Errorf("close vsock listener on port %d: %w", listener.port, err)
	}

	return nil
}
