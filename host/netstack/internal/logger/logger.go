// Package logger provides a terminal-aware logger that collapses consecutive
// identical messages into a single line with a repeat counter ("… [3x]"),
// keeping the display noise low when the same network error fires many times
// in a row. The timestamp on a repeated line is always the latest occurrence.
//
// Deduplication is active only when the output is a TTY. Non-TTY outputs
// (pipes, files) receive every line verbatim, which is correct for log
// consumers that expect an unmodified stream.
//
// Comparison is on the raw message string, before the timestamp is added,
// so the logic is independent of the timestamp format.
package logger

import (
	"fmt"
	"io"
	"os"
	"sync"
	"time"
)

// Logger is a dedup-aware logger.
type Logger struct {
	mu      sync.Mutex
	out     io.Writer
	isTTY   bool
	prefix  string
	lastMsg string
	count   int // consecutive repetitions of lastMsg seen so far
}

// New creates a Logger that writes to f with the given prefix.
// The prefix is inserted between the timestamp and the message body,
// matching the behaviour of log.SetPrefix with log.Lmsgprefix.
// TTY detection is performed automatically; deduplication is active only
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
	l.output(fmt.Sprintf(format, args...), false)
}

// Println emits a log line from a plain string.
func (l *Logger) Println(msg string) {
	l.output(msg, false)
}

// Fatalf formats and emits a log line, then calls os.Exit(1).
func (l *Logger) Fatalf(format string, args ...any) {
	l.output(fmt.Sprintf(format, args...), true)
	os.Exit(1)
}

// Fatal emits a log line, then calls os.Exit(1).
func (l *Logger) Fatal(msg string) {
	l.output(msg, true)
	os.Exit(1)
}

// output is the single write path. final=true always terminates the line with
// a newline (used by Fatal/Fatalf so the exit leaves the terminal clean).
func (l *Logger) output(msg string, final bool) {
	ts := time.Now().Format("15:04:05")
	line := ts + " " + l.prefix + msg

	l.mu.Lock()
	defer l.mu.Unlock()

	if !l.isTTY {
		fmt.Fprintln(l.out, line) //nolint:errcheck
		return
	}

	isDup := l.count > 0 && msg == l.lastMsg
	if isDup {
		l.count++
		if final {
			fmt.Fprintf(l.out, "\r\033[K%s [%dx]\n", line, l.count) //nolint:errcheck
			l.count = 0
		} else {
			fmt.Fprintf(l.out, "\r\033[K%s [%dx]", line, l.count) //nolint:errcheck
		}
		return
	}

	if l.count > 0 {
		fmt.Fprintln(l.out, "") //nolint:errcheck // terminate previous held line
	}

	if final {
		fmt.Fprintln(l.out, line) //nolint:errcheck
		l.count = 0
	} else {
		fmt.Fprint(l.out, line) //nolint:errcheck
		l.lastMsg = msg
		l.count = 1
	}
}
