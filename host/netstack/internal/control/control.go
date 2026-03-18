// Package control implements the JSON control socket server for dvm-netstack.
// dvm-core sends config (secrets, CA, subnet) and commands over this socket.
package control

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
)

// SecretRule is a resolved secret passed from dvm-core.
type SecretRule struct {
	Name        string   `json:"name"`
	Hosts       []string `json:"hosts"`
	Placeholder string   `json:"placeholder"`
	Value       string   `json:"value"`
	Inject      Inject   `json:"inject"`
}

// Inject describes how a secret is injected into requests.
type Inject struct {
	Type string `json:"type"` // "bearer", "basic", "header"
	Name string `json:"name"` // header name (for type="header")
}

// NetConfig is the initial configuration sent by dvm-core.
type NetConfig struct {
	Subnet     string       `json:"subnet"`
	GatewayIP  string       `json:"gateway_ip"`
	GuestIP    string       `json:"guest_ip"`
	GuestMAC   string       `json:"guest_mac"`
	DNSServers []string     `json:"dns_servers"`
	CACertPEM  string       `json:"ca_cert_pem"`
	CAKeyPEM   string       `json:"ca_key_pem"`
	Secrets    []SecretRule `json:"secrets"`
}

// Request is a message from dvm-core to the sidecar.
type Request struct {
	Type string `json:"type"` // "load_config", "load", "unload", "status", "shutdown"

	// For load_config (initial) and load (per-project reload)
	Config *NetConfig `json:"config,omitempty"`

	// For load/unload (per-project)
	ProjectRoot string       `json:"project_root,omitempty"`
	Secrets     []SecretRule `json:"secrets,omitempty"`
}

// Response is a message from the sidecar to dvm-core.
type Response struct {
	Type      string      `json:"type"` // "ready", "ok", "status", "error"
	GuestIP   string      `json:"guest_ip,omitempty"`
	CACertPEM string      `json:"ca_cert_pem,omitempty"`
	Error     string      `json:"error,omitempty"`
	Status    *StatusInfo `json:"status,omitempty"`
}

// StatusInfo carries health/status details.
type StatusInfo struct {
	Healthy     bool `json:"healthy"`
	SecretCount int  `json:"secret_count"`
}

// StackInfo is implemented by the network stack to provide status and secret updates.
type StackInfo interface {
	SecretCount() int
	UpdateSecrets(secrets []SecretRule)
}

// Server manages the Unix domain control socket.
type Server struct {
	listener   net.Listener
	sockPath   string
	configCh   chan NetConfig
	shutdownCh chan struct{}
	readyCh    chan struct{} // closed when stack is ready

	mu        sync.Mutex
	stack     StackInfo
	projects  map[string][]SecretRule // project_root -> secrets
	caCertPEM string                 // set by SendReady, returned in ready response
}

// NewServer creates a control socket server at the given path.
func NewServer(sockPath string) (*Server, error) {
	// Remove stale socket.
	os.Remove(sockPath)

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		return nil, fmt.Errorf("listen %s: %w", sockPath, err)
	}

	s := &Server{
		listener:   ln,
		sockPath:   sockPath,
		configCh:   make(chan NetConfig, 1),
		shutdownCh: make(chan struct{}),
		readyCh:    make(chan struct{}),
		projects:   make(map[string][]SecretRule),
	}

	go s.acceptLoop()
	return s, nil
}

// WaitForConfig blocks until the initial load_config message arrives.
func (s *Server) WaitForConfig() NetConfig {
	return <-s.configCh
}

// ShutdownCh returns a channel that is closed when a shutdown command arrives.
func (s *Server) ShutdownCh() <-chan struct{} {
	return s.shutdownCh
}

// SetStack sets the network stack reference for status queries.
func (s *Server) SetStack(si StackInfo) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stack = si
}

// SendReady signals that the stack is up and provides the CA cert PEM.
// This unblocks the load_config handler which is waiting to send the ready response.
func (s *Server) SendReady(caCertPEM string) {
	s.mu.Lock()
	s.caCertPEM = caCertPEM
	s.mu.Unlock()
	close(s.readyCh)
}

// Close shuts down the control socket.
func (s *Server) Close() error {
	s.listener.Close()
	os.Remove(s.sockPath)
	return nil
}

// mergedSecrets returns the combined secret rules from all projects.
// Caller must hold s.mu.
func (s *Server) mergedSecrets() []SecretRule {
	var merged []SecretRule
	for _, secrets := range s.projects {
		merged = append(merged, secrets...)
	}
	return merged
}

func (s *Server) acceptLoop() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return
		}
		go s.handleConn(conn)
	}
}

func (s *Server) handleConn(conn net.Conn) {
	defer conn.Close()

	dec := json.NewDecoder(conn)
	enc := json.NewEncoder(conn)

	for {
		var req Request
		if err := dec.Decode(&req); err != nil {
			if err != io.EOF {
				log.Printf("control: decode error: %v", err)
			}
			return
		}

		resp := s.handleRequest(&req)
		if err := enc.Encode(resp); err != nil {
			log.Printf("control: encode error: %v", err)
			return
		}
	}
}

func (s *Server) handleRequest(req *Request) *Response {
	switch req.Type {
	case "load_config":
		if req.Config == nil {
			return &Response{Type: "error", Error: "load_config: missing config"}
		}
		// Store initial secrets under a default project key.
		s.mu.Lock()
		if len(req.Config.Secrets) > 0 {
			s.projects["_default"] = req.Config.Secrets
		}
		s.mu.Unlock()
		// Non-blocking send; first config wins.
		// Don't respond yet — main.go will call SendReady() after the stack is up.
		select {
		case s.configCh <- *req.Config:
		default:
		}
		// Block until the stack is ready and we have the CA cert PEM.
		s.mu.Lock()
		readyCh := s.readyCh
		s.mu.Unlock()
		if readyCh != nil {
			<-readyCh
		}
		s.mu.Lock()
		caPEM := s.caCertPEM
		s.mu.Unlock()
		return &Response{Type: "ready", GuestIP: req.Config.GuestIP, CACertPEM: caPEM}

	case "load":
		// Per-project secret reload.
		s.mu.Lock()
		st := s.stack
		if req.ProjectRoot == "" {
			s.mu.Unlock()
			return &Response{Type: "error", Error: "load: missing project_root"}
		}
		s.projects[req.ProjectRoot] = req.Secrets
		merged := s.mergedSecrets()
		s.mu.Unlock()
		if st == nil {
			return &Response{Type: "error", Error: "stack not initialized"}
		}
		st.UpdateSecrets(merged)
		return &Response{Type: "ok"}

	case "unload":
		// Remove a project's secrets and rebuild merged set.
		s.mu.Lock()
		st := s.stack
		if req.ProjectRoot != "" {
			delete(s.projects, req.ProjectRoot)
		}
		merged := s.mergedSecrets()
		s.mu.Unlock()
		if st == nil {
			return &Response{Type: "error", Error: "stack not initialized"}
		}
		st.UpdateSecrets(merged)
		return &Response{Type: "ok"}

	case "status":
		s.mu.Lock()
		st := s.stack
		s.mu.Unlock()
		info := &StatusInfo{Healthy: st != nil}
		if st != nil {
			info.SecretCount = st.SecretCount()
		}
		return &Response{Type: "status", Status: info}

	case "shutdown":
		log.Println("control: shutdown requested")
		select {
		case <-s.shutdownCh:
		default:
			close(s.shutdownCh)
		}
		return &Response{Type: "ok"}

	default:
		return &Response{Type: "error", Error: fmt.Sprintf("unknown request type: %q", req.Type)}
	}
}
