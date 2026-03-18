// Package stack initializes a gVisor userspace TCP/IP stack using gvisor-tap-vsock
// for the networking foundation (DHCP, DNS, frame I/O) and adds credential-aware
// HTTP/HTTPS interception on top.
package stack

import (
	"context"
	"fmt"
	"syscall"
	"log"
	"net"
	"os"
	"sync"
	"time"

	"github.com/containers/gvisor-tap-vsock/pkg/services/dhcp"
	gvdns "github.com/containers/gvisor-tap-vsock/pkg/services/dns"
	"github.com/containers/gvisor-tap-vsock/pkg/tap"
	"github.com/containers/gvisor-tap-vsock/pkg/types"
	"github.com/unbody/darvm/netstack/internal/control"
	"github.com/unbody/darvm/netstack/internal/proxy"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/network/arp"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	gstack "gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/icmp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

const (
	udpDropLogInterval = 60 * time.Second
)

// Config configures the network stack.
type Config struct {
	FrameConn  net.Conn
	GatewayIP  string
	GuestIP    string
	GuestMAC   string
	MTU        uint32
	DNSServers []string
	Secrets    []control.SecretRule
	CACertPEM  string
	CAKeyPEM   string
}

// CACertPEM returns the CA certificate PEM (for guest trust store installation).
func (ns *Stack) CACertPEM() string { return ns.caCertPEM }

// Stack is the gVisor-based network stack with credential interception.
type Stack struct {
	caCertPEM string
	gstack      *gstack.Stack
	netSwitch   *tap.Switch
	interceptor *proxy.Interceptor
	secrets     []control.SecretRule
	frameConn   net.Conn
	cancelSwitch context.CancelFunc

	mu     sync.Mutex
	closed bool

	udpDropMu   sync.Mutex
	udpDropSeen map[string]time.Time
}

// New creates and starts a network stack using gvisor-tap-vsock for the
// networking foundation and our own TCP handler for credential interception.
func New(cfg *Config) (*Stack, error) {
	gatewayMAC := "02:00:00:00:00:01"

	// Create the gvisor-tap-vsock configuration
	gvConfig := &types.Configuration{
		Debug:             false,
		MTU:               int(cfg.MTU),
		Subnet:            "192.168.64.0/24",
		GatewayIP:         cfg.GatewayIP,
		GatewayMacAddress: gatewayMAC,
		DHCPStaticLeases: map[string]string{
			cfg.GuestIP: cfg.GuestMAC,
		},
		// Empty DNS zones = forward all queries to host's upstream resolver
		// (gvisor-tap-vsock uses net.Resolver by default for unmatched queries)
		DNS: []types.Zone{},
	}

	// Parse subnet
	_, subnet, err := net.ParseCIDR(gvConfig.Subnet)
	if err != nil {
		return nil, fmt.Errorf("parse subnet: %w", err)
	}

	// IP pool for DHCP
	ipPool := tap.NewIPPool(subnet)
	ipPool.Reserve(net.ParseIP(gvConfig.GatewayIP), gatewayMAC)
	for ip, mac := range gvConfig.DHCPStaticLeases {
		ipPool.Reserve(net.ParseIP(ip), mac)
	}

	// Create the tap endpoint and switch (frame I/O layer)
	tapEndpoint, err := tap.NewLinkEndpoint(false, cfg.MTU, gatewayMAC, cfg.GatewayIP, nil)
	if err != nil {
		return nil, fmt.Errorf("tap endpoint: %w", err)
	}
	netSwitch := tap.NewSwitch(false)
	tapEndpoint.Connect(netSwitch)
	netSwitch.Connect(tapEndpoint)

	// Create the gVisor stack
	s := gstack.New(gstack.Options{
		NetworkProtocols: []gstack.NetworkProtocolFactory{
			ipv4.NewProtocol,
			arp.NewProtocol,
		},
		TransportProtocols: []gstack.TransportProtocolFactory{
			tcp.NewProtocol,
			udp.NewProtocol,
			icmp.NewProtocol4,
		},
	})

	if tcpipErr := s.CreateNIC(1, tapEndpoint); tcpipErr != nil {
		return nil, fmt.Errorf("create NIC: %v", tcpipErr)
	}

	gatewayAddr := tcpip.AddrFrom4Slice(net.ParseIP(cfg.GatewayIP).To4())
	if tcpipErr := s.AddProtocolAddress(1, tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: gatewayAddr.WithPrefix(),
	}, gstack.AddressProperties{}); tcpipErr != nil {
		return nil, fmt.Errorf("add address: %v", tcpipErr)
	}

	s.SetRouteTable([]tcpip.Route{{
		Destination: header.IPv4EmptySubnet,
		NIC:         1,
	}})
	s.SetPromiscuousMode(1, true)
	s.SetSpoofing(1, true)

	// Start DHCP server (uses gvisor-tap-vsock's battle-tested implementation)
	dhcpServer, err := dhcp.New(gvConfig, s, ipPool)
	if err != nil {
		return nil, fmt.Errorf("dhcp: %w", err)
	}
	go func() {
		if err := dhcpServer.Serve(); err != nil {
			log.Printf("dhcp server error: %v", err)
		}
	}()
	log.Println("dhcp: server started")

	// Start DNS server
	udpConn, err := gonet.DialUDP(s, &tcpip.FullAddress{
		NIC:  1,
		Addr: gatewayAddr,
		Port: 53,
	}, nil, ipv4.ProtocolNumber)
	if err != nil {
		return nil, fmt.Errorf("dns udp bind: %w", err)
	}
	tcpLn, err := gonet.ListenTCP(s, tcpip.FullAddress{
		NIC:  1,
		Addr: gatewayAddr,
		Port: 53,
	}, ipv4.ProtocolNumber)
	if err != nil {
		return nil, fmt.Errorf("dns tcp bind: %w", err)
	}
	dnsServer, err := gvdns.New(udpConn, tcpLn, gvConfig.DNS)
	if err != nil {
		return nil, fmt.Errorf("dns server: %w", err)
	}
	go func() { _ = dnsServer.Serve() }()
	go func() { _ = dnsServer.ServeTCP() }()
	log.Println("dns: server started")

	// Credential interception.
	// If no CA PEM provided, generate one in Go (more reliable than Swift DER builder).
	var caPool *proxy.CAPool
	if cfg.CACertPEM != "" && cfg.CAKeyPEM != "" {
		var err2 error
		caPool, err2 = proxy.NewCAPool(cfg.CACertPEM, cfg.CAKeyPEM)
		if err2 != nil {
			return nil, fmt.Errorf("CA pool: %w", err2)
		}
	} else {
		var certPEM string
		var err2 error
		caPool, certPEM, err2 = proxy.GenerateCA()
		if err2 != nil {
			return nil, fmt.Errorf("generate CA: %w", err2)
		}
		cfg.CACertPEM = certPEM
		log.Printf("generated ephemeral MITM CA (%d bytes PEM)", len(certPEM))
	}
	interceptor := proxy.NewInterceptor(cfg.Secrets, caPool)

	// The frame conn is a SOCK_DGRAM unix socket wrapping the VZ socketpair.
	// VfkitProtocol = bare L2 frames over SOCK_DGRAM.
	frameConn := cfg.FrameConn
	switchCtx, cancelSwitch := context.WithCancel(context.Background())

	ns := &Stack{
		caCertPEM:    cfg.CACertPEM,
		gstack:       s,
		netSwitch:    netSwitch,
		interceptor:  interceptor,
		secrets:      cfg.Secrets,
		frameConn:    frameConn,
		cancelSwitch: cancelSwitch,
		udpDropSeen:  make(map[string]time.Time),
	}

	// TCP forwarder: intercept credentialed hosts, passthrough everything else
	tcpForwarder := tcp.NewForwarder(s, 0, 65535, ns.handleTCPConnection)
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpForwarder.HandlePacket)

	// No UDP forwarder — DNS and DHCP are handled by their own bound endpoints
	// from gvisor-tap-vsock. Installing a generic UDP forwarder would conflict
	// with those bound endpoints and steal their traffic.

	// Connect the socketpair to the switch
	go func() {
		if err := netSwitch.Accept(switchCtx, frameConn, types.VfkitProtocol); err != nil {
			if !ns.isClosed() {
				log.Printf("switch accept error: %v", err)
			}
		}
	}()

	return ns, nil
}

// SecretCount returns the number of loaded secret rules.
func (ns *Stack) SecretCount() int {
	ns.mu.Lock()
	defer ns.mu.Unlock()
	return len(ns.secrets)
}

// UpdateSecrets atomically replaces the secret rules.
func (ns *Stack) UpdateSecrets(secrets []control.SecretRule) {
	ns.mu.Lock()
	ns.secrets = secrets
	ns.mu.Unlock()
	ns.interceptor.UpdateSecrets(secrets)
}

func (ns *Stack) isClosed() bool {
	ns.mu.Lock()
	defer ns.mu.Unlock()
	return ns.closed
}

// Close tears down the network stack.
func (ns *Stack) Close() error {
	ns.mu.Lock()
	defer ns.mu.Unlock()
	if ns.closed {
		return nil
	}
	ns.closed = true
	ns.cancelSwitch()
	ns.frameConn.Close()
	ns.gstack.Close()
	return nil
}

func (ns *Stack) handleTCPConnection(r *tcp.ForwarderRequest) {
	id := r.ID()
	dstPort := id.LocalPort
	dstIP := id.LocalAddress.String()

	var wq waiter.Queue
	ep, tcpipErr := r.CreateEndpoint(&wq)
	if tcpipErr != nil {
		r.Complete(true)
		return
	}
	r.Complete(false)
	guestConn := gonet.NewTCPConn(&wq, ep)

	switch dstPort {
	case 80:
		go ns.interceptor.HandleHTTP(guestConn, dstIP, int(dstPort))
	case 443:
		go ns.interceptor.HandleHTTPS(guestConn, dstIP, int(dstPort))
	default:
		go ns.handlePassthrough(guestConn, dstIP, int(dstPort))
	}
}

func (ns *Stack) handlePassthrough(guestConn net.Conn, dstIP string, dstPort int) {
	defer guestConn.Close()
	target := net.JoinHostPort(dstIP, fmt.Sprintf("%d", dstPort))
	realConn, err := net.Dial("tcp", target)
	if err != nil {
		log.Printf("passthrough: dial %s: %v", target, err)
		return
	}
	defer realConn.Close()

	done := make(chan struct{})
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := realConn.Read(buf)
			if n > 0 {
				guestConn.Write(buf[:n])
			}
			if err != nil {
				break
			}
		}
		close(done)
	}()
	buf := make([]byte, 32*1024)
	for {
		n, err := guestConn.Read(buf)
		if n > 0 {
			realConn.Write(buf[:n])
		}
		if err != nil {
			break
		}
	}
	<-done
}

// dupFD creates a new *os.File by dup'ing the FD from the given file.
// This is needed because os.NewFile takes ownership and net.FileConn
// also dups, but the original FD from the inherited socketpair may not
// be in a state that net.FileConn can work with directly.
func dupFD(f *os.File) (*os.File, error) {
	fd, err := syscall.Dup(int(f.Fd()))
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), f.Name()+"-dup"), nil
}

func (ns *Stack) handleUDPPacket(r *udp.ForwarderRequest) bool {
	id := r.ID()
	// DNS and DHCP are handled by their own bound endpoints.
	// Everything else is dropped with rate-limited logging.
	dst := fmt.Sprintf("%s:%d", id.LocalAddress, id.LocalPort)
	ns.udpDropMu.Lock()
	last, seen := ns.udpDropSeen[dst]
	now := time.Now()
	if !seen || now.Sub(last) >= udpDropLogInterval {
		ns.udpDropSeen[dst] = now
		ns.udpDropMu.Unlock()
		log.Printf("udp: traffic to %s dropped (only DNS and DHCP forwarded in v1)", dst)
	} else {
		ns.udpDropMu.Unlock()
	}
	return true
}

