package vsock

import (
	"errors"
	"fmt"
	"log"
	"math"
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
	// Keep the listener in blocking mode. grpc.Server expects Accept to block
	// until a connection arrives; nonblocking AF_VSOCK listeners surface EAGAIN
	// as a fatal Serve error and make the guest RPC daemon flap.

	file, err := newFileFromFD(fd, "vsock")
	if err != nil {
		if closeErr := unix.Close(fd); closeErr != nil {
			log.Printf("vsock: close listener fd=%d after invalid fd conversion: %v", fd, closeErr)
		}

		return nil, fmt.Errorf("wrap vsock listener on port %d: %w", port, err)
	}

	fileFD, err := fileDescriptorInt(file)
	if err != nil {
		if closeErr := file.Close(); closeErr != nil {
			log.Printf("vsock: close listener file after invalid fd conversion on port %d: %v", port, closeErr)
		}

		return nil, fmt.Errorf("resolve listener fd on port %d: %w", port, err)
	}

	if err := unix.Bind(fileFD, &unix.SockaddrVM{
		CID:  unix.VMADDR_CID_ANY,
		Port: port,
	}); err != nil {
		if closeErr := file.Close(); closeErr != nil {
			log.Printf("vsock: close listener file after bind failure on port %d: %v", port, closeErr)
		}

		return nil, fmt.Errorf("bind vsock listener on port %d: %w", port, err)
	}

	if err := unix.Listen(fileFD, unix.SOMAXCONN); err != nil {
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
	listenerFD, err := fileDescriptorInt(listener.file)
	if err != nil {
		return nil, fmt.Errorf("resolve listener fd on port %d: %w", listener.port, err)
	}

	fd, _, err := unix.Accept(listenerFD)
	if err != nil {
		return nil, fmt.Errorf("accept vsock connection on port %d: %w", listener.port, err)
	}

	file, err := newFileFromFD(fd, "vsock")
	if err != nil {
		if closeErr := unix.Close(fd); closeErr != nil {
			log.Printf("vsock: close accepted fd=%d after invalid fd conversion: %v", fd, closeErr)
		}

		return nil, fmt.Errorf("wrap accepted vsock connection on port %d: %w", listener.port, err)
	}

	fileFD, err := fileDescriptorInt(file)
	if err != nil {
		if closeErr := file.Close(); closeErr != nil {
			log.Printf("vsock: close accepted file after invalid fd conversion on port %d: %v", listener.port, closeErr)
		}

		return nil, fmt.Errorf("resolve accepted fd on port %d: %w", listener.port, err)
	}

	peerName, err := unix.Getpeername(fileFD)
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

func newFileFromFD(fd int, name string) (*os.File, error) {
	fdValue, err := nonNegativeIntToUintptr(fd)
	if err != nil {
		return nil, err
	}

	return os.NewFile(fdValue, name), nil
}

func fileDescriptorInt(file *os.File) (int, error) {
	fd := file.Fd()
	if fd > math.MaxInt {
		return 0, fmt.Errorf("file descriptor %d exceeds int range", fd)
	}

	return int(fd), nil
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
