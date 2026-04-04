package vsock

import (
	"fmt"
	"net"
	"os"
	"time"
)

type conn struct {
	file       *os.File
	localPort  uint32
	remotePort uint32
}

func (conn *conn) Read(b []byte) (n int, err error) {
	n, err = conn.file.Read(b)
	if err != nil {
		return n, fmt.Errorf("read vsock port %d: %w", conn.localPort, err)
	}
	return n, nil
}

func (conn *conn) Write(b []byte) (n int, err error) {
	n, err = conn.file.Write(b)
	if err != nil {
		return n, fmt.Errorf("write vsock port %d: %w", conn.remotePort, err)
	}
	return n, nil
}

func (conn *conn) SetDeadline(t time.Time) error {
	if err := conn.file.SetDeadline(t); err != nil {
		return fmt.Errorf("set vsock deadline: %w", err)
	}
	return nil
}

func (conn *conn) SetReadDeadline(t time.Time) error {
	if err := conn.file.SetReadDeadline(t); err != nil {
		return fmt.Errorf("set vsock read deadline: %w", err)
	}
	return nil
}

func (conn *conn) SetWriteDeadline(t time.Time) error {
	if err := conn.file.SetWriteDeadline(t); err != nil {
		return fmt.Errorf("set vsock write deadline: %w", err)
	}
	return nil
}

func (conn *conn) LocalAddr() net.Addr {
	return &addr{port: conn.localPort}
}

func (conn *conn) RemoteAddr() net.Addr {
	return &addr{port: conn.remotePort}
}

func (conn *conn) Close() error {
	if err := conn.file.Close(); err != nil {
		return fmt.Errorf("close vsock port %d: %w", conn.localPort, err)
	}
	return nil
}
