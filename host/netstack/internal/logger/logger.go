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

// Logger is a newline-terminated logger with optional TTY styling.
type Logger struct {
	mu     sync.Mutex
	out    io.Writer
	isTTY  bool
	prefix string
}

// New creates a Logger that writes to f with the given prefix.
// The prefix is inserted between the timestamp and the message body,
// matching the behaviour of log.SetPrefix with log.Lmsgprefix.
// TTY detection is performed automatically; ANSI styling is active only
// when the output is a terminal.
func New(f *os.File, prefix string) *Logger {
	fi, err := f.Stat()
	isTTY := err == nil && fi.Mode()&(os.ModeDevice|os.ModeCharDevice) == os.ModeDevice|os.ModeCharDevice
	return newLogger(f, isTTY, prefix)
}

// newLogger is the internal constructor used by tests to inject a plain
// io.Writer with an explicit TTY flag.
func newLogger(w io.Writer, isTTY bool, prefix string) *Logger {
	return &Logger{out: w, isTTY: isTTY, prefix: prefix}
}

// Printf formats and emits a log line.
func (l *Logger) Printf(format string, args ...any) {
	l.output(fmt.Sprintf(format, args...))
}

// Println emits a log line from a plain string.
func (l *Logger) Println(msg string) {
	l.output(msg)
}

// Fatalf formats and emits a log line, then calls os.Exit(1).
func (l *Logger) Fatalf(format string, args ...any) {
	l.output(fmt.Sprintf(format, args...))
	os.Exit(1)
}

// Fatal emits a log line, then calls os.Exit(1).
func (l *Logger) Fatal(msg string) {
	l.output(msg)
	os.Exit(1)
}

func (l *Logger) output(msg string) {
	ts := time.Now().Format("15:04:05")
	line := ts + " " + l.prefix + msg
	if l.isTTY {
		line = styleLine(ts, l.prefix, msg)
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	fmt.Fprintln(l.out, line) //nolint:errcheck
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
