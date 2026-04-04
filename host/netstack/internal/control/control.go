// Package control implements the JSON control socket server for dvm-netstack.
// dvm-core sends config (secrets, CA, subnet) and commands over this socket.
package control

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
)

// SecretRule is a resolved secret passed from dvm-core.
// The proxy replaces Placeholder with Value in HTTPS request headers for
// matching Hosts. No inject modes — the guest tool decides how to use the
// placeholder (Authorization header, query param, etc.).
type SecretRule struct {
	Name        string   `json:"name"`
	Hosts       []string `json:"hosts"`
	Placeholder string   `json:"placeholder"`
	Value       string   `json:"value"`
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
	Type string `json:"type"` // "load_config", "load", "status", "shutdown"

	// For load_config (initial)
	Config *NetConfig `json:"config,omitempty"`

	// For load (per-project credential push)
	ProjectName string       `json:"project_name,omitempty"`
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
	projects  map[string][]SecretRule // project_name -> secrets
	caCertPEM string                  // set by SendReady, returned in ready response
}

// NewServer creates a control socket server at the given path.
func NewServer(sockPath string) (*Server, error) {
	// Remove stale socket.
	if err := os.Remove(sockPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("remove stale socket %s: %w", sockPath, err)
	}

	ln, err := (&net.ListenConfig{}).Listen(context.Background(), "unix", sockPath)
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
	var errs []error
	if err := s.listener.Close(); err != nil {
		errs = append(errs, err)
	}

	if err := os.Remove(s.sockPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		errs = append(errs, err)
	}

	return errors.Join(errs...)
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

// checkCollisions detects placeholder conflicts across projects.
// Same placeholder + different value in a different project is an error.
// Same project name is fine (overwrite). Caller must hold s.mu.
func (s *Server) checkCollisions(incomingProject string, incoming []SecretRule) error {
	for projName, existing := range s.projects {
		if projName == incomingProject {
			continue // same project — will be overwritten
		}

		for _, es := range existing {
			for _, is := range incoming {
				if es.Placeholder == is.Placeholder && es.Value != is.Value {
					return fmt.Errorf("load: placeholder collision: %q has different values in projects %q and %q",
						es.Placeholder, projName, incomingProject)
				}
			}
		}
	}

	return nil
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
	defer func() {
		if err := conn.Close(); err != nil {
			log.Printf("control: close conn: %v", err)
		}
	}()

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
		// No secrets at startup — credentials are pushed per-project at exec time.
		// Non-blocking send; first config wins.
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
		// Per-project credential push. Same project name overwrites previous.
		s.mu.Lock()

		st := s.stack
		if st == nil {
			s.mu.Unlock()

			return &Response{Type: "error", Error: "stack not initialized"}
		}

		if req.ProjectName == "" {
			s.mu.Unlock()

			return &Response{Type: "error", Error: "load: missing project_name"}
		}
		// Collision detection: same placeholder with different value across
		// different projects is an error (indicates a placeholder derivation bug
		// or two projects claiming the same identity).
		if err := s.checkCollisions(req.ProjectName, req.Secrets); err != nil {
			s.mu.Unlock()

			return &Response{Type: "error", Error: err.Error()}
		}

		s.projects[req.ProjectName] = req.Secrets
		merged := s.mergedSecrets()
		st.UpdateSecrets(merged)
		s.mu.Unlock()

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
