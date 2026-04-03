package rpc

import (
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/user"
	"slices"
	"strings"

	"github.com/creack/pty"
	pb "github.com/unbody/darvm/agent/gen"
	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc"
)

const (
	standardStreamsBufferSize = 4096
	eofChar                   = 0x04
	execUID                   = 501 // UID of the primary VM user (admin or renamed)
)

func (rpc *RPC) Exec(stream grpc.BidiStreamingServer[pb.ExecRequest, pb.ExecResponse]) error {
	// First request must describe the command to execute
	firstReq, err := stream.Recv()
	if err != nil {
		return err
	}
	cmdReq, ok := firstReq.Type.(*pb.ExecRequest_Command)
	if !ok {
		return fmt.Errorf("first exec request must describe a command")
	}

	command := cmdReq.Command
	log.Printf("exec: %s (tty=%v interactive=%v cwd=%q)", formatCommandAndArgs(command.Name, command.Args),
		command.Tty, command.Interactive, command.WorkingDirectory)

	// Run as the UID 501 user (admin in base image, may be renamed to host username).
	// Resolved dynamically so the agent doesn't need restarting after rename.
	// The agent daemon runs as root but commands should execute as the
	// normal user — callers prepend "sudo" when they need root.
	//
	// Uses "sudo -iu <user>" for a login shell environment (nix in PATH).
	// Working directory: sudo -i resets cwd to $HOME, so we wrap in
	// sh -c 'cd <dir> && exec ...' when a cwd is specified.
	// TTY sessions get TERM=xterm-256color injected (sudo -i resets env).
	execUser := resolveUID501User()

	// Build env prefix: TERM for TTY + any env vars from the gRPC request.
	// These are prepended to the shell command so they survive sudo -iu's env reset.
	var envParts []string
	if command.Tty {
		envParts = append(envParts, "export TERM=xterm-256color")
	}
	for _, ev := range command.Environment {
		envParts = append(envParts, fmt.Sprintf("export %s=%s", ev.Name, shellQuote(ev.Value)))
	}
	var envPrefix string
	if len(envParts) > 0 {
		envPrefix = strings.Join(envParts, "; ") + "; "
	}

	var cmd *exec.Cmd
	if command.Name == "sudo" {
		cmd = exec.CommandContext(stream.Context(), command.Name, command.Args...)
		if command.WorkingDirectory != "" {
			cmd.Dir = command.WorkingDirectory
		}
		// For sudo commands, inject env vars directly into cmd.Env if present.
		if len(command.Environment) > 0 {
			cmd.Env = os.Environ()
			for _, ev := range command.Environment {
				cmd.Env = append(cmd.Env, ev.Name+"="+ev.Value)
			}
		}
	} else if command.WorkingDirectory != "" || envPrefix != "" {
		inner := shellQuote(command.Name)
		for _, a := range command.Args {
			inner += " " + shellQuote(a)
		}
		var shellCmd string
		if command.WorkingDirectory != "" {
			shellCmd = fmt.Sprintf("%scd %s && exec %s", envPrefix, shellQuote(command.WorkingDirectory), inner)
		} else {
			shellCmd = fmt.Sprintf("%sexec %s", envPrefix, inner)
		}
		args := []string{"-iu", execUser, "--", "sh", "-c", shellCmd}
		cmd = exec.CommandContext(stream.Context(), "sudo", args...)
	} else {
		args := append([]string{"-iu", execUser, "--", command.Name}, command.Args...)
		cmd = exec.CommandContext(stream.Context(), "sudo", args...)
	}

	var stdin io.WriteCloser
	var stdout, stderr io.ReadCloser
	var ptmx *os.File

	if command.Tty {
		ptmx, err = pty.StartWithSize(cmd, &pty.Winsize{
			Rows: uint16(command.GetTerminalSize().GetRows()),
			Cols: uint16(command.GetTerminalSize().GetCols()),
		})
		if command.Interactive {
			stdin = ptmx
		}
		stdout = ptmx
		stderr = ptmx
	} else {
		if command.Interactive {
			stdin, err = cmd.StdinPipe()
			if err != nil {
				return err
			}
		}

		stdout, err = cmd.StdoutPipe()
		if err != nil {
			return err
		}

		stderr, err = cmd.StderrPipe()
		if err != nil {
			return err
		}

		err = cmd.Start()
	}
	if err != nil {
		return err
	}
	if ptmx != nil {
		defer func() {
			if closeErr := ptmx.Close(); closeErr != nil {
				log.Printf("close PTY: %v", closeErr)
			}
		}()
	}

	// Handle stdin and terminal resize from client
	fromClientErrCh := make(chan error, 1)

	go func() {
		for {
			request, err := stream.Recv()
			if err != nil {
				if !errors.Is(err, io.EOF) {
					fromClientErrCh <- err
				}
				return
			}

			switch typed := request.Type.(type) {
			case *pb.ExecRequest_StandardInput:
				if !command.Interactive {
					continue
				}

				data := typed.StandardInput.Data

				if len(data) == 0 {
					if command.Tty {
						// PTY: send EOF character instead of closing
						data = []byte{eofChar}
					} else {
						if err := stdin.Close(); err != nil {
							fromClientErrCh <- err
							return
						}
						continue
					}
				}

				if _, err := stdin.Write(data); err != nil {
					fromClientErrCh <- err
					return
				}

			case *pb.ExecRequest_TerminalResize:
				if !command.Tty {
					continue
				}
				if err := pty.Setsize(ptmx, &pty.Winsize{
					Rows: uint16(typed.TerminalResize.GetRows()),
					Cols: uint16(typed.TerminalResize.GetCols()),
				}); err != nil {
					fromClientErrCh <- err
					return
				}
			}
		}
	}()

	group, _ := errgroup.WithContext(stream.Context())

	// Stream stdout
	group.Go(func() error {
		buf := make([]byte, standardStreamsBufferSize)
		for {
			n, err := stdout.Read(buf)
			if err != nil {
				if errors.Is(err, io.EOF) {
					return nil
				}
				// PTY way of signalling EOF
				if ptmx != nil && strings.Contains(err.Error(), "input/output error") {
					return nil
				}
				return err
			}

			if err := stream.Send(&pb.ExecResponse{
				Type: &pb.ExecResponse_StandardOutput{
					StandardOutput: &pb.IOChunk{
						Data: slices.Clone(buf[:n]),
					},
				},
			}); err != nil {
				return err
			}
		}
	})

	// Stream stderr (only when not using TTY)
	if !command.Tty {
		group.Go(func() error {
			buf := make([]byte, standardStreamsBufferSize)
			for {
				n, err := stderr.Read(buf)
				if err != nil {
					if errors.Is(err, io.EOF) {
						return nil
					}
					return err
				}

				if err := stream.Send(&pb.ExecResponse{
					Type: &pb.ExecResponse_StandardError{
						StandardError: &pb.IOChunk{
							Data: slices.Clone(buf[:n]),
						},
					},
				}); err != nil {
					return err
				}
			}
		})
	}

	if err := group.Wait(); err != nil {
		log.Printf("exec stream: %v", err)
	}

	// Wait for command to finish
	exitCode := int32(0)
	if err := cmd.Wait(); err != nil {
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			exitCode = int32(exitError.ExitCode())
		} else {
			return err
		}
	}

	return stream.Send(&pb.ExecResponse{
		Type: &pb.ExecResponse_Exit{
			Exit: &pb.Exit{
				Code: exitCode,
			},
		},
	})
}

// resolveUID501User returns the username for UID 501.
// This is the primary VM user — "admin" in the base image, potentially
// renamed to the host username by dvm-core at startup.
func resolveUID501User() string {
	u, err := user.LookupId("501")
	if err != nil {
		return "admin"
	}
	return u.Username
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

func formatCommandAndArgs(name string, args []string) string {
	all := append([]string{name}, args...)
	quoted := make([]string, len(all))
	for i, s := range all {
		quoted[i] = fmt.Sprintf("%q", s)
	}
	return fmt.Sprintf("[%s]", strings.Join(quoted, ", "))
}
