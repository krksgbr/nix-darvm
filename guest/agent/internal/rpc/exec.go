package rpc

import (
	"errors"
	"fmt"
	"io"
	"log"
	"math"
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

var errFirstExecRequestNotCommand = errors.New("first exec request must describe a command")

func (rpc *RPC) Exec(stream grpc.BidiStreamingServer[pb.ExecRequest, pb.ExecResponse]) error {
	// First request must describe the command to execute
	firstReq, err := stream.Recv()
	if err != nil {
		return fmt.Errorf("receive exec command: %w", err)
	}

	cmdReq, ok := firstReq.GetType().(*pb.ExecRequest_Command)
	if !ok {
		return errFirstExecRequestNotCommand
	}

	command := cmdReq.Command
	log.Printf("exec: %s (tty=%v interactive=%v cwd=%q)", formatCommandAndArgs(command.GetName(), command.GetArgs()),
		command.GetTty(), command.GetInteractive(), command.GetWorkingDirectory())

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
	if command.GetTty() {
		envParts = append(envParts, "export TERM=xterm-256color")
	}

	for _, ev := range command.GetEnvironment() {
		envParts = append(envParts, fmt.Sprintf("export %s=%s", ev.GetName(), shellQuote(ev.GetValue())))
	}

	var envPrefix string
	if len(envParts) > 0 {
		envPrefix = strings.Join(envParts, "; ") + "; "
	}

	var cmd *exec.Cmd
	if command.GetName() == "sudo" {
		cmd = exec.CommandContext(stream.Context(), command.GetName(), command.GetArgs()...) //nolint:gosec // Exec is an explicit remote command execution API.
		configureDirectSudoCommand(cmd, command)
	} else if command.GetWorkingDirectory() != "" || envPrefix != "" {
		inner := shellQuote(command.GetName())
		var innerSb81 strings.Builder
		for _, a := range command.GetArgs() {
			innerSb81.WriteString(" " + shellQuote(a))
		}
		inner += innerSb81.String()

		var shellCmd string
		if command.GetWorkingDirectory() != "" {
			shellCmd = fmt.Sprintf("%scd %s && exec %s", envPrefix, shellQuote(command.GetWorkingDirectory()), inner)
		} else {
			shellCmd = fmt.Sprintf("%sexec %s", envPrefix, inner)
		}

		args := []string{"-iu", execUser, "--", "sh", "-c", shellCmd}
		cmd = exec.CommandContext(stream.Context(), "sudo", args...) //nolint:gosec // Exec is an explicit remote command execution API.
	} else {
		args := append([]string{"-iu", execUser, "--", command.GetName()}, command.GetArgs()...)
		cmd = exec.CommandContext(stream.Context(), "sudo", args...) //nolint:gosec // Exec is an explicit remote command execution API.
	}

	var (
		stdin          io.WriteCloser
		stdout, stderr io.ReadCloser
		ptmx           *os.File
	)

	if command.GetTty() {
		stdin, stdout, stderr, ptmx, err = startTTYCommand(cmd, command)
	} else {
		stdin, stdout, stderr, err = startPipeCommand(cmd, command)
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
					fromClientErrCh <- fmt.Errorf("receive exec stream input: %w", err)
				}

				return
			}

			switch typed := request.GetType().(type) {
			case *pb.ExecRequest_StandardInput:
				if !command.GetInteractive() {
					continue
				}

				data := typed.StandardInput.GetData()

				if len(data) == 0 {
					if command.GetTty() {
						// PTY: send EOF character instead of closing
						data = []byte{eofChar}
					} else {
						if err := stdin.Close(); err != nil {
							fromClientErrCh <- fmt.Errorf("close exec stdin: %w", err)

							return
						}

						continue
					}
				}

				if _, err := stdin.Write(data); err != nil {
					fromClientErrCh <- fmt.Errorf("write exec stdin: %w", err)

					return
				}

			case *pb.ExecRequest_TerminalResize:
				if !command.GetTty() {
					continue
				}

				rows, err := uint32ToUint16(typed.TerminalResize.GetRows(), "resize terminal rows")
				if err != nil {
					fromClientErrCh <- err

					return
				}

				cols, err := uint32ToUint16(typed.TerminalResize.GetCols(), "resize terminal cols")
				if err != nil {
					fromClientErrCh <- err

					return
				}

				if err := pty.Setsize(ptmx, &pty.Winsize{
					Rows: rows,
					Cols: cols,
				}); err != nil {
					fromClientErrCh <- fmt.Errorf("resize exec terminal: %w", err)

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

				return fmt.Errorf("read exec stdout: %w", err)
			}

			if err := stream.Send(&pb.ExecResponse{
				Type: &pb.ExecResponse_StandardOutput{
					StandardOutput: &pb.IOChunk{
						Data: slices.Clone(buf[:n]),
					},
				},
			}); err != nil {
				return fmt.Errorf("send exec stdout: %w", err)
			}
		}
	})

	// Stream stderr (only when not using TTY)
	if !command.GetTty() {
		group.Go(func() error {
			buf := make([]byte, standardStreamsBufferSize)
			for {
				n, err := stderr.Read(buf)
				if err != nil {
					if errors.Is(err, io.EOF) {
						return nil
					}

					return fmt.Errorf("read exec stderr: %w", err)
				}

				if err := stream.Send(&pb.ExecResponse{
					Type: &pb.ExecResponse_StandardError{
						StandardError: &pb.IOChunk{
							Data: slices.Clone(buf[:n]),
						},
					},
				}); err != nil {
					return fmt.Errorf("send exec stderr: %w", err)
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
			exitCode, err = intToInt32(exitError.ExitCode(), "command exit code")
			if err != nil {
				return err
			}
		} else {
			return fmt.Errorf("wait for command %s: %w", formatCommandAndArgs(command.GetName(), command.GetArgs()), err)
		}
	}

	if err := stream.Send(&pb.ExecResponse{
		Type: &pb.ExecResponse_Exit{
			Exit: &pb.Exit{
				Code: exitCode,
			},
		},
	}); err != nil {
		return fmt.Errorf("send exec exit status: %w", err)
	}

	return nil
}

// resolveUID501User returns the username for UID 501.
// This is the primary VM user — "admin" in the base image, potentially
// renamed to the host username by dvm-core at startup.
func configureDirectSudoCommand(cmd *exec.Cmd, command *pb.Command) {
	if cwd := command.GetWorkingDirectory(); cwd != "" {
		cmd.Dir = cwd
	}

	if len(command.GetEnvironment()) == 0 {
		return
	}

	cmd.Env = os.Environ()
	for _, ev := range command.GetEnvironment() {
		cmd.Env = append(cmd.Env, ev.GetName()+"="+ev.GetValue())
	}
}

func startTTYCommand(cmd *exec.Cmd, command *pb.Command) (
	io.WriteCloser,
	io.ReadCloser,
	io.ReadCloser,
	*os.File,
	error,
) {
	rows, err := uint32ToUint16(command.GetTerminalSize().GetRows(), "initial terminal rows")
	if err != nil {
		return nil, nil, nil, nil, err
	}

	cols, err := uint32ToUint16(command.GetTerminalSize().GetCols(), "initial terminal cols")
	if err != nil {
		return nil, nil, nil, nil, err
	}

	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{
		Rows: rows,
		Cols: cols,
	})
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf(
			"start command %s: %w",
			formatCommandAndArgs(command.GetName(), command.GetArgs()),
			err,
		)
	}

	var stdin io.WriteCloser
	if command.GetInteractive() {
		stdin = ptmx
	}

	return stdin, ptmx, ptmx, ptmx, nil
}

func startPipeCommand(cmd *exec.Cmd, command *pb.Command) (io.WriteCloser, io.ReadCloser, io.ReadCloser, error) {
	var stdin io.WriteCloser
	var err error
	if command.GetInteractive() {
		stdin, err = cmd.StdinPipe()
		if err != nil {
			return nil, nil, nil, fmt.Errorf("open stdin pipe: %w", err)
		}
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, nil, fmt.Errorf("open stdout pipe: %w", err)
	}

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, nil, nil, fmt.Errorf("open stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return nil, nil, nil, fmt.Errorf(
			"start command %s: %w",
			formatCommandAndArgs(command.GetName(), command.GetArgs()),
			err,
		)
	}

	return stdin, stdout, stderr, nil
}

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

func uint32ToUint16(v uint32, field string) (uint16, error) {
	if v > math.MaxUint16 {
		return 0, fmt.Errorf("%s %d exceeds uint16 range", field, v)
	}

	return uint16(v), nil
}

func intToInt32(v int, field string) (int32, error) {
	if v < math.MinInt32 || v > math.MaxInt32 {
		return 0, fmt.Errorf("%s %d exceeds int32 range", field, v)
	}

	return int32(v), nil
}
