package logger

import (
	"bytes"
	"strings"
	"testing"
)

// msg strips the "HH:MM:SS prefix" leader from a raw log line so tests can
// assert on message content without depending on exact timestamps.
func stripTimestamp(line string) string {
	const tsLen = 9
	if len(line) <= tsLen {
		return line
	}
	return line[tsLen:]
}

func lines(s string) []string {
	parts := strings.Split(s, "\n")
	if len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

func TestNonTTYEachCallWritesOneLine(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, false, "x: ")

	l.Printf("hello %s", "world")

	got := lines(buf.String())
	if len(got) != 1 {
		t.Fatalf("expected 1 line, got %d: %q", len(got), buf.String())
	}
	if !strings.Contains(stripTimestamp(got[0]), "x: hello world") {
		t.Fatalf("unexpected line content %q", got[0])
	}
}

func TestNonTTYHasNoEscapeCodes(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, false, "x: ")

	l.Printf("msg")
	l.Printf("msg")

	if strings.Contains(buf.String(), "\x1b[") {
		t.Fatalf("non-TTY output must not contain ANSI, got %q", buf.String())
	}
}

func TestTTYAlwaysTerminatesEachLine(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, true, "x: ")

	l.Printf("first")
	l.Printf("second")

	got := lines(buf.String())
	if len(got) != 2 {
		t.Fatalf("expected 2 newline-terminated lines, got %d: %q", len(got), buf.String())
	}
}

func TestTTYStylesTimestampAndPrefix(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, true, "dvm-netstack: ")

	l.Printf("network stack running")

	out := buf.String()
	if !strings.Contains(out, ansiDim) {
		t.Fatalf("expected dim timestamp styling, got %q", out)
	}
	if !strings.Contains(out, ansiCyan+"dvm-netstack: "+ansiReset) {
		t.Fatalf("expected cyan prefix styling, got %q", out)
	}
}

func TestTTYStylesWarningsAndErrors(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, true, "dvm-netstack: ")

	l.Printf("Warning: fallback mode")
	l.Printf("ERROR: boom")

	out := buf.String()
	if !strings.Contains(out, ansiYellow) {
		t.Fatalf("expected warning styling, got %q", out)
	}
	if !strings.Contains(out, ansiRed) {
		t.Fatalf("expected error styling, got %q", out)
	}
}

func TestPrintlnWritesMessage(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, false, "x: ")

	l.Println("plain message")

	if !strings.Contains(buf.String(), "x: plain message") {
		t.Fatalf("expected message in output, got %q", buf.String())
	}
}
