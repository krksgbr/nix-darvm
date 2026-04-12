// Package logger provides a terminal-aware logger for dvm-netstack.
//
// TTY output gets restrained ANSI styling to improve scanability during
// `dvm start`, but every call still writes a newline-terminated record so
// mixed host + sidecar output cannot collapse into a single unreadable line.
// Non-TTY outputs (pipes, files) receive every line verbatim without ANSI.
package logger

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	ansiReset  = "\x1b[0m"
	ansiBold   = "\x1b[1m"
	ansiDim    = "\x1b[2m"
	ansiRed    = "\x1b[31m"
	ansiYellow = "\x1b[33m"
	ansiCyan   = "\x1b[36m"
)

type outputMode uint8

const (
	outputTerminal outputMode = 1 << iota
	outputDiagnostic
	outputBoth = outputTerminal | outputDiagnostic
)

// Logger is a newline-terminated logger with optional TTY styling.
type Logger struct {
	mu              sync.Mutex
	out             io.Writer
	diagnostic      io.Writer
	diagCloser      io.Closer
	diagnosticPath  string
	suppressedCount int
	isTTY           bool
	prefix          string
}

// New creates a Logger that writes to f with the given prefix.
// The prefix is inserted between the timestamp and the message body,
// matching the behaviour of log.SetPrefix with log.Lmsgprefix.
// TTY detection is performed automatically; ANSI styling is active only
// when the output is a terminal.
func New(f *os.File, prefix string) *Logger {
	fi, err := f.Stat()
	isTTY := err == nil && fi.Mode()&(os.ModeDevice|os.ModeCharDevice) == os.ModeDevice|os.ModeCharDevice
	return newLogger(f, nil, isTTY, prefix)
}

// SetDiagnosticFile configures a plain, lossless diagnostic sink.
// Diagnostic output is never ANSI-styled and is independent from terminal
// filtering decisions made by higher layers.
func (l *Logger) SetDiagnosticFile(path string) error {
	cleanPath := filepath.Clean(path)
	file, err := os.Create(cleanPath) // #nosec G304 -- path comes from the host-controlled sidecar control socket path
	if err != nil {
		return fmt.Errorf("open diagnostic log %s: %w", path, err)
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	if l.diagCloser != nil {
		if closeErr := l.diagCloser.Close(); closeErr != nil {
			_ = file.Close()
			return fmt.Errorf("replace diagnostic log: close previous sink: %w", closeErr)
		}
	}

	l.diagnostic = file
	l.diagCloser = file
	l.diagnosticPath = cleanPath
	l.suppressedCount = 0
	return nil
}

// CloseDiagnosticFile closes the configured diagnostic sink, if any.
func (l *Logger) CloseDiagnosticFile() error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.diagCloser == nil {
		return nil
	}

	err := l.diagCloser.Close()
	l.diagnostic = nil
	l.diagCloser = nil
	l.diagnosticPath = ""
	l.suppressedCount = 0
	if err != nil {
		return fmt.Errorf("close diagnostic log: %w", err)
	}

	return nil
}

// newLogger is the internal constructor used by tests to inject a plain
// io.Writer with an explicit TTY flag.
func newLogger(w io.Writer, diagnostic io.Writer, isTTY bool, prefix string) *Logger {
	return &Logger{out: w, diagnostic: diagnostic, isTTY: isTTY, prefix: prefix}
}

// Suppressedln emits a diagnostic-only line and tracks that it was hidden from
// the live terminal stream.
func (l *Logger) Suppressedln(msg string) {
	l.mu.Lock()
	l.suppressedCount++
	l.mu.Unlock()
	l.output(msg, outputDiagnostic)
}

// DiagnosticPath returns the configured raw diagnostic log path, if any.
func (l *Logger) DiagnosticPath() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.diagnosticPath
}

// SuppressedCount returns the number of terminal-suppressed messages emitted.
func (l *Logger) SuppressedCount() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.suppressedCount
}

// EmitSuppressedSummary prints one terminal-visible summary if any messages
// were hidden from the live terminal stream.
func (l *Logger) EmitSuppressedSummary() {
	l.mu.Lock()
	count := l.suppressedCount
	path := l.diagnosticPath
	l.mu.Unlock()

	if count == 0 {
		return
	}

	message := fmt.Sprintf("suppressed %d background passthrough log(s); raw diagnostics: %s", count, path)
	l.output(message, outputBoth)
}

// Printf formats and emits a log line.
func (l *Logger) Printf(format string, args ...any) {
	l.output(fmt.Sprintf(format, args...), outputBoth)
}

// Println emits a log line from a plain string.
func (l *Logger) Println(msg string) {
	l.output(msg, outputBoth)
}

// Diagnosticf emits a log line only to the diagnostic sink.
func (l *Logger) Diagnosticf(format string, args ...any) {
	l.output(fmt.Sprintf(format, args...), outputDiagnostic)
}

// Diagnosticln emits a plain log line only to the diagnostic sink.
func (l *Logger) Diagnosticln(msg string) {
	l.output(msg, outputDiagnostic)
}

// Fatalf formats and emits a log line, then calls os.Exit(1).
func (l *Logger) Fatalf(format string, args ...any) {
	l.output(fmt.Sprintf(format, args...), outputBoth)
	os.Exit(1)
}

// Fatal emits a log line, then calls os.Exit(1).
func (l *Logger) Fatal(msg string) {
	l.output(msg, outputBoth)
	os.Exit(1)
}

func (l *Logger) output(msg string, mode outputMode) {
	ts := time.Now().Format("15:04:05")
	plainLine := ts + " " + l.prefix + msg
	terminalLine := plainLine
	if l.isTTY {
		terminalLine = styleLine(ts, l.prefix, msg)
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	if mode&outputDiagnostic != 0 && l.diagnostic != nil {
		fmt.Fprintln(l.diagnostic, plainLine) //nolint:errcheck
	}
	if mode&outputTerminal != 0 {
		fmt.Fprintln(l.out, terminalLine) //nolint:errcheck
	}
}

func styleLine(ts, prefix, msg string) string {
	styledMsg := msg
	switch {
	case strings.HasPrefix(msg, "Warning:"):
		styledMsg = wrap(msg, ansiBold+ansiYellow)
	case strings.HasPrefix(msg, "FATAL:") || strings.HasPrefix(msg, "ERROR:") || strings.Contains(msg, " failed"):
		styledMsg = wrap(msg, ansiBold+ansiRed)
	}

	return wrap(ts, ansiDim) + " " + wrap(prefix, ansiDim+ansiCyan) + styledMsg
}

func wrap(text, style string) string {
	return style + text + ansiReset
}
