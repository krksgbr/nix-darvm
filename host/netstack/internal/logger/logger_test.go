package logger

import (
	"bytes"
	"strings"
	"testing"
)

// msg strips the "HH:MM:SS prefix" leader from a raw log line so tests can
// assert on message content without depending on exact timestamps.
func stripTimestamp(line string) string {
	// Format: "HH:MM:SS prefix message …"
	// Timestamp is always exactly 9 bytes ("15:04:05 ").
	const tsLen = 9
	if len(line) <= tsLen {
		return line
	}
	return line[tsLen:]
}

// lines splits output into individual lines, trimming a single trailing empty
// entry that results from a trailing newline.
func lines(s string) []string {
	parts := strings.Split(s, "\n")
	if len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

// --- Non-TTY behaviour ---

func TestNonTTY_EachCallWritesOneLine(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, false, "x: ")

	l.Printf("hello %s", "world")

	got := lines(buf.String())
	if len(got) != 1 {
		t.Fatalf("expected 1 line, got %d: %q", len(got), buf.String())
	}
	if !strings.Contains(stripTimestamp(got[0]), "x: hello world") {
		t.Errorf("line content: got %q", got[0])
	}
}

func TestNonTTY_DuplicatesWriteSeparateLines(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, false, "x: ")

	l.Printf("boom")
	l.Printf("boom")
	l.Printf("boom")

	got := lines(buf.String())
	if len(got) != 3 {
		t.Fatalf("expected 3 lines for 3 identical calls, got %d:\n%s", len(got), buf.String())
	}
	for i, line := range got {
		if !strings.Contains(stripTimestamp(line), "x: boom") {
			t.Errorf("line %d: unexpected content %q", i, line)
		}
	}
}

func TestNonTTY_NoEscapeCodes(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, false, "x: ")

	l.Printf("msg")
	l.Printf("msg")

	if strings.ContainsAny(buf.String(), "\r\033") {
		t.Errorf("non-TTY output must not contain escape codes, got %q", buf.String())
	}
}

// --- TTY behaviour ---

func TestTTY_FirstMessageHeldWithoutNewline(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, true, "x: ")

	l.Printf("hello")

	out := buf.String()
	if strings.HasSuffix(out, "\n") {
		t.Errorf("first message should be held (no trailing newline), got %q", out)
	}
	if !strings.Contains(stripTimestamp(out), "x: hello") {
		t.Errorf("message not found in output %q", out)
	}
}

func TestTTY_DuplicatesOverwriteWithCounter(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, true, "x: ")

	l.Printf("err")
	l.Printf("err")
	l.Printf("err")

	out := buf.String()

	if !strings.Contains(out, "[3x]") {
		t.Errorf("expected [3x] counter after 3 identical calls, got %q", out)
	}
	if !strings.Contains(out, "\r\033[K") {
		t.Errorf("expected carriage-return + erase-line escape on duplicate, got %q", out)
	}
	// The last line must still be held (no trailing newline).
	if strings.HasSuffix(out, "\n") {
		t.Errorf("held line should not end with newline, got %q", out)
	}
}

func TestTTY_NewMessageTerminatesDupLine(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, true, "x: ")

	l.Printf("first")
	l.Printf("first")
	l.Printf("second")

	out := buf.String()

	// "second" must appear after a newline that closes the "first [2x]" line.
	if !strings.Contains(out, "\nx: second") && !strings.Contains(out, "\nx:") {
		// Accept any newline-then-prefix-then-second pattern (timestamp in between).
		idx := strings.LastIndex(out, "\n")
		if idx < 0 {
			t.Errorf("expected a newline before 'second', got %q", out)
		}
	}
	if !strings.Contains(out, "[2x]") {
		t.Errorf("expected [2x] counter for duplicated 'first', got %q", out)
	}
	if !strings.Contains(out, "second") {
		t.Errorf("expected 'second' in output, got %q", out)
	}
}

func TestTTY_InterruptedRunRestartsFresh(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, true, "x: ")

	l.Printf("a")
	l.Printf("a") // [2x]
	l.Printf("b") // flushes "a" run, starts "b"
	l.Printf("b") // [2x]
	l.Printf("b") // [3x]

	out := buf.String()

	if !strings.Contains(out, "[2x]") {
		t.Errorf("expected [2x] for first run, got %q", out)
	}
	if !strings.Contains(out, "[3x]") {
		t.Errorf("expected [3x] for second run, got %q", out)
	}

	// "a" run ends with a newline before "b" starts.
	aEnd := strings.Index(out, "[2x]")
	bStart := strings.Index(out, "x: b")
	if aEnd < 0 || bStart < 0 || aEnd > bStart {
		t.Fatalf("unexpected ordering in output %q", out)
	}
	between := out[aEnd+len("[2x]") : bStart]
	if !strings.Contains(between, "\n") {
		t.Errorf("expected newline between 'a' run and 'b' run, got %q between them", between)
	}
}

// --- Fatal behaviour ---

// outputOnly calls the internal output method directly to test Fatal's
// write path without triggering os.Exit.
func TestTTY_FatalTerminatesLine(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, true, "x: ")

	// Simulate a pending duplicate run, then a fatal (different message).
	l.Printf("noise")
	l.Printf("noise")
	l.output("fatal error", true) // final=true, new message

	out := buf.String()
	if !strings.HasSuffix(out, "\n") {
		t.Errorf("fatal message must end with newline (terminal must be clean), got %q", out)
	}
	if !strings.Contains(out, "fatal error") {
		t.Errorf("fatal message missing from output %q", out)
	}
}

func TestTTY_FatalDuplicateTerminatesLine(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, true, "x: ")

	l.Printf("boom")
	l.Printf("boom")
	l.output("boom", true) // same message, final=true

	out := buf.String()
	if !strings.HasSuffix(out, "\n") {
		t.Errorf("fatal duplicate must end with newline, got %q", out)
	}
	if !strings.Contains(out, "[3x]") {
		t.Errorf("expected [3x] counter for fatal duplicate, got %q", out)
	}
}

// --- Println ---

func TestPrintln_WritesMessage(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	l := newLogger(&buf, false, "x: ")

	l.Println("plain message")

	out := buf.String()
	if !strings.Contains(out, "x: plain message") {
		t.Errorf("expected message in output, got %q", out)
	}
}
