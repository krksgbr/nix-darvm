package control

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"testing"
	"time"
)

// dial connects to the control socket and returns a JSON encoder/decoder pair.
func dial(t *testing.T, sockPath string) (*json.Encoder, *json.Decoder) {
	t.Helper()
	conn, err := (&net.Dialer{Timeout: 2 * time.Second}).DialContext(context.Background(), "unix", sockPath)
	if err != nil {
		t.Fatalf("dial control socket: %v", err)
	}
	t.Cleanup(func() {
		if err := conn.Close(); err != nil {
			t.Errorf("close control conn: %v", err)
		}
	})
	return json.NewEncoder(conn), json.NewDecoder(conn)
}

// shortSockPath returns a short unix socket path under /tmp to avoid the
// 104-byte macOS limit on unix socket paths.
func shortSockPath(t *testing.T) string {
	t.Helper()
	f, err := os.CreateTemp("/tmp", "ctrl-*.sock")
	if err != nil {
		t.Fatalf("create temp: %v", err)
	}
	path := f.Name()
	if err := f.Close(); err != nil {
		t.Fatalf("close temp socket placeholder: %v", err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatalf("remove temp socket placeholder: %v", err)
	}
	t.Cleanup(func() {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			t.Errorf("remove temp socket path: %v", err)
		}
	})
	return path
}

// initServer creates a control server, sends load_config, and returns the
// server ready for load commands.
func initServer(t *testing.T) *Server {
	t.Helper()
	sock := shortSockPath(t)
	srv, err := NewServer(sock)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	t.Cleanup(func() {
		if err := srv.Close(); err != nil {
			t.Errorf("close server: %v", err)
		}
	})

	// The stack must be set and ready before load commands work.
	srv.SetStack(&fakeStack{})
	srv.SendReady("")

	// Send load_config to unblock the server.
	enc, dec := dial(t, sock)
	if err := enc.Encode(Request{
		Type:   "load_config",
		Config: &NetConfig{GuestIP: "192.168.64.2"},
	}); err != nil {
		t.Fatalf("encode load_config: %v", err)
	}
	var resp Response
	if err := dec.Decode(&resp); err != nil {
		t.Fatalf("decode ready: %v", err)
	}
	if resp.Type != "ready" {
		t.Fatalf("expected ready, got %q: %s", resp.Type, resp.Error)
	}

	return srv
}

// sendLoad sends a load request on a fresh connection and returns the response.
func sendLoad(t *testing.T, sockPath, project string, secrets []SecretRule) Response {
	t.Helper()
	enc, dec := dial(t, sockPath)
	if err := enc.Encode(Request{
		Type:        "load",
		ProjectName: project,
		Secrets:     secrets,
	}); err != nil {
		t.Fatalf("encode load: %v", err)
	}
	var resp Response
	if err := dec.Decode(&resp); err != nil {
		t.Fatalf("decode load response: %v", err)
	}
	return resp
}

type fakeStack struct {
	secrets []SecretRule
}

func (f *fakeStack) SecretCount() int             { return len(f.secrets) }
func (f *fakeStack) UpdateSecrets(s []SecretRule) { f.secrets = s }

func TestLoad_SameProjectOverwrites(t *testing.T) {
	srv := initServer(t)

	resp := sendLoad(t, srv.sockPath, "myproj", []SecretRule{{
		Name: "KEY", Hosts: []string{"api.example.com"}, Placeholder: "PH_1", Value: "val-1",
	}})
	if resp.Type != "ok" {
		t.Fatalf("first load: %s", resp.Error)
	}

	// Same project, different value for same placeholder — overwrite, not collision.
	resp = sendLoad(t, srv.sockPath, "myproj", []SecretRule{{
		Name: "KEY", Hosts: []string{"api.example.com"}, Placeholder: "PH_1", Value: "val-2",
	}})
	if resp.Type != "ok" {
		t.Fatalf("second load (same project) should succeed: %s", resp.Error)
	}
}

func TestLoad_CollisionDifferentProjects(t *testing.T) {
	srv := initServer(t)

	resp := sendLoad(t, srv.sockPath, "proj-a", []SecretRule{{
		Name: "KEY", Hosts: []string{"api.example.com"}, Placeholder: "SHARED_PH", Value: "val-a",
	}})
	if resp.Type != "ok" {
		t.Fatalf("proj-a load: %s", resp.Error)
	}

	// Different project, same placeholder, different value — collision.
	resp = sendLoad(t, srv.sockPath, "proj-b", []SecretRule{{
		Name: "KEY", Hosts: []string{"api.example.com"}, Placeholder: "SHARED_PH", Value: "val-b",
	}})
	if resp.Type != "error" {
		t.Fatal("expected collision error for same placeholder with different value")
	}
	if resp.Error == "" {
		t.Fatal("expected non-empty error message")
	}
}

func TestLoad_SamePlaceholderSameValueNoCrash(t *testing.T) {
	srv := initServer(t)

	resp := sendLoad(t, srv.sockPath, "proj-a", []SecretRule{{
		Name: "KEY", Hosts: []string{"api.example.com"}, Placeholder: "SHARED_PH", Value: "same-val",
	}})
	if resp.Type != "ok" {
		t.Fatalf("proj-a load: %s", resp.Error)
	}

	// Different project, same placeholder, same value — no collision.
	resp = sendLoad(t, srv.sockPath, "proj-b", []SecretRule{{
		Name: "KEY", Hosts: []string{"api.example.com"}, Placeholder: "SHARED_PH", Value: "same-val",
	}})
	if resp.Type != "ok" {
		t.Fatalf("same placeholder + same value should not collide: %s", resp.Error)
	}
}

func TestLoad_MissingProjectName(t *testing.T) {
	srv := initServer(t)
	resp := sendLoad(t, srv.sockPath, "", []SecretRule{{
		Name: "KEY", Hosts: []string{"api.example.com"}, Placeholder: "PH", Value: "val",
	}})
	if resp.Type != "error" {
		t.Fatal("expected error for empty project name")
	}
}
