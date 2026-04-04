// dvm-netstack is a Go sidecar that provides transparent network interception
// for DVM's credential proxy. It reads raw Ethernet frames from an inherited
// socketpair FD, processes them through gVisor's userspace TCP/IP stack, and
// can intercept HTTP/HTTPS traffic to inject credentials.
package main

import (
	"flag"
	"fmt"
	"log"
	"math"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/unbody/darvm/netstack/internal/control"
	"github.com/unbody/darvm/netstack/internal/stack"
)

func main() {
	frameFD := flag.Int("frame-fd", -1, "file descriptor for the socketpair carrying raw Ethernet frames")
	controlSock := flag.String("control-sock", "", "path to the Unix domain control socket")

	flag.Parse()

	if *frameFD < 0 {
		fmt.Fprintln(os.Stderr, "error: --frame-fd is required")
		os.Exit(1)
	}

	if *controlSock == "" {
		fmt.Fprintln(os.Stderr, "error: --control-sock is required")
		os.Exit(1)
	}

	log.SetPrefix("dvm-netstack: ")
	log.SetFlags(log.Ltime | log.Lmsgprefix)

	// Wrap the inherited FD into a net.Conn immediately to prevent the GC
	// from finalizing the os.File and closing the FD before we use it.
	frameFDValue, err := nonNegativeIntToUintptr(*frameFD)
	if err != nil {
		log.Fatalf("invalid frame FD %d: %v", *frameFD, err)
	}

	frameFile := os.NewFile(frameFDValue, "frame-fd")
	if frameFile == nil {
		log.Fatal("failed to open frame FD")
	}

	frameConn, err := net.FileConn(frameFile)
	if err != nil {
		log.Fatalf("failed to wrap frame FD as net.Conn: %v", err)
	}

	if err := frameFile.Close(); err != nil { // FileConn dups internally
		log.Fatalf("failed to close duplicated frame file: %v", err)
	}

	// Create the control server. Config (secrets, CA, subnet) arrives
	// over this socket after startup — never via argv or env.
	ctrl, err := control.NewServer(*controlSock)
	if err != nil {
		log.Fatalf("control socket: %v", err)
	}

	defer func() {
		if err := ctrl.Close(); err != nil {
			log.Printf("control socket shutdown: %v", err)
		}
	}()

	// Wait for initial config before starting the network stack.
	log.Println("waiting for config on control socket...")

	cfg := ctrl.WaitForConfig()
	log.Printf("config received: subnet=%s gateway=%s guest=%s dns=%v",
		cfg.Subnet, cfg.GatewayIP, cfg.GuestIP, cfg.DNSServers)

	// Initialize the gVisor network stack.
	ns, err := stack.New(&stack.Config{
		FrameConn:  frameConn,
		Subnet:     cfg.Subnet,
		GatewayIP:  cfg.GatewayIP,
		GuestIP:    cfg.GuestIP,
		GuestMAC:   cfg.GuestMAC,
		MTU:        1500,
		DNSServers: cfg.DNSServers,
		Secrets:    cfg.Secrets,
		CACertPEM:  cfg.CACertPEM,
		CAKeyPEM:   cfg.CAKeyPEM,
	})
	if err != nil {
		log.Fatalf("network stack: %v", err)
	}

	defer func() {
		if err := ns.Close(); err != nil {
			log.Printf("network stack shutdown: %v", err)
		}
	}()

	// Tell dvm-core we're ready (includes the CA cert PEM for guest trust store).
	ctrl.SetStack(ns)
	ctrl.SendReady(ns.CACertPEM())
	log.Println("network stack running")

	// Block until SIGTERM/SIGINT or shutdown command.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	select {
	case sig := <-sigCh:
		log.Printf("received %s, shutting down", sig)
	case <-ctrl.ShutdownCh():
		log.Println("shutdown requested via control socket")
	}
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
