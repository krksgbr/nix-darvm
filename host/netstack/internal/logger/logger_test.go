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
	l := newLogger(&buf, nil, false, "x: ")

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
	l := newLogger(&buf, nil, false, "x: ")

	l.Printf("msg")
	l.Printf("msg")

	if strings.Contains(buf.String(), "\x1b[") {
		t.Fatalf("non-TTY output must not contain ANSI, got %q", buf.String())
	}
}

func TestTTYAlwaysTerminatesEachLine(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, nil, true, "x: ")

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
	l := newLogger(&buf, nil, true, "dvm-netstack: ")

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
	l := newLogger(&buf, nil, true, "dvm-netstack: ")

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
	l := newLogger(&buf, nil, false, "x: ")

	l.Println("plain message")

	if !strings.Contains(buf.String(), "x: plain message") {
		t.Fatalf("expected message in output, got %q", buf.String())
	}
}

func TestDiagnosticSinkGetsPlainCopyOfTerminalLogs(t *testing.T) {
	t.Parallel()
	var terminal bytes.Buffer
	var diagnostic bytes.Buffer
	l := newLogger(&terminal, &diagnostic, true, "x: ")

	l.Printf("hello")

	diagLines := lines(diagnostic.String())
	if len(diagLines) != 1 {
		t.Fatalf("expected 1 diagnostic line, got %d: %q", len(diagLines), diagnostic.String())
	}
	if strings.Contains(diagnostic.String(), "\x1b[") {
		t.Fatalf("diagnostic output must stay plain, got %q", diagnostic.String())
	}
	if !strings.Contains(stripTimestamp(diagLines[0]), "x: hello") {
		t.Fatalf("unexpected diagnostic content %q", diagLines[0])
	}
}

func TestDiagnosticOnlyDoesNotWriteToTerminal(t *testing.T) {
	t.Parallel()
	var terminal bytes.Buffer
	var diagnostic bytes.Buffer
	l := newLogger(&terminal, &diagnostic, true, "x: ")

	l.Diagnosticln("suppressed noise")

	if terminal.Len() != 0 {
		t.Fatalf("expected terminal output to stay empty, got %q", terminal.String())
	}
	if !strings.Contains(diagnostic.String(), "suppressed noise") {
		t.Fatalf("expected diagnostic output, got %q", diagnostic.String())
	}
}

func TestSuppressedlnIncrementsCounterWithoutWritingTerminal(t *testing.T) {
	t.Parallel()
	var terminal bytes.Buffer
	var diagnostic bytes.Buffer
	l := newLogger(&terminal, &diagnostic, true, "x: ")

	l.Suppressedln("background noise")

	if got := l.SuppressedCount(); got != 1 {
		t.Fatalf("expected suppressed count 1, got %d", got)
	}
	if terminal.Len() != 0 {
		t.Fatalf("expected terminal output to stay empty, got %q", terminal.String())
	}
	if !strings.Contains(diagnostic.String(), "background noise") {
		t.Fatalf("expected diagnostic output, got %q", diagnostic.String())
	}
}

func TestEmitSuppressedSummaryPrintsTerminalSummary(t *testing.T) {
	t.Parallel()
	var terminal bytes.Buffer
	var diagnostic bytes.Buffer
	l := newLogger(&terminal, &diagnostic, false, "x: ")
	l.diagnosticPath = "/tmp/dvm-netstack.raw.log"

	l.Suppressedln("background noise")
	l.EmitSuppressedSummary()

	if !strings.Contains(terminal.String(), "suppressed 1 background passthrough log(s)") {
		t.Fatalf("expected terminal summary, got %q", terminal.String())
	}
	if !strings.Contains(terminal.String(), "/tmp/dvm-netstack.raw.log") {
		t.Fatalf("expected diagnostic path in summary, got %q", terminal.String())
	}
	if !strings.Contains(diagnostic.String(), "suppressed 1 background passthrough log(s)") {
		t.Fatalf("expected summary copied to diagnostics, got %q", diagnostic.String())
	}
}
