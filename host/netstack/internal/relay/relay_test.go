package relay

import (
	"errors"
	"net"
	"testing"
)

func TestResultsToLogSuppressesFollowOnCloseNoiseAfterCleanCompletion(t *testing.T) {
	t.Parallel()

	results := [2]Result{
		{Operation: "guest to upstream copy", Err: nil},
		{Operation: "upstream to guest copy", Err: errors.New("read tcp 1.2.3.4:443: read: connection reset by peer")},
	}

	got := ResultsToLog(results)
	if len(got) != 0 {
		t.Fatalf("expected no loggable results, got %#v", got)
	}
}

func TestResultsToLogKeepsFirstObservableCloseLikeFailure(t *testing.T) {
	t.Parallel()

	results := [2]Result{
		{Operation: "guest to upstream copy", Err: errors.New("write tcp 1.2.3.4:443: write: broken pipe")},
		{Operation: "upstream to guest copy", Err: net.ErrClosed},
	}

	got := ResultsToLog(results)
	if len(got) != 1 {
		t.Fatalf("expected 1 loggable result, got %#v", got)
	}
	if got[0].Operation != "guest to upstream copy" {
		t.Fatalf("expected first relay result to be kept, got %#v", got)
	}
}

func TestResultsToLogKeepsFollowOnNonCloseFailure(t *testing.T) {
	t.Parallel()

	results := [2]Result{
		{Operation: "guest to upstream copy", Err: nil},
		{Operation: "upstream to guest copy", Err: errors.New("read: operation timed out")},
	}

	got := ResultsToLog(results)
	if len(got) != 1 {
		t.Fatalf("expected 1 loggable result, got %#v", got)
	}
	if got[0].Operation != "upstream to guest copy" {
		t.Fatalf("expected timeout to remain loggable, got %#v", got)
	}
}

func TestIsTimeout(t *testing.T) {
	t.Parallel()

	if !IsTimeout(timeoutError{}) {
		t.Fatal("expected timeout error to be recognized")
	}
	if !IsTimeout(errors.New("read tcp: operation timed out")) {
		t.Fatal("expected timeout string fallback to be recognized")
	}
	if IsTimeout(errors.New("connection reset by peer")) {
		t.Fatal("did not expect non-timeout error to match")
	}
}

func TestIsKnownAppleBackgroundHost(t *testing.T) {
	t.Parallel()

	if !IsKnownAppleBackgroundHost("GDMF.apple.com.") {
		t.Fatal("expected normalized Apple background host to match")
	}
	if !IsKnownAppleBackgroundHost("api-safari-aeun1a.smoot.apple.com") {
		t.Fatal("expected known background suffix host to match")
	}
	if !IsKnownAppleBackgroundHost("weather-edge.apple.com") {
		t.Fatal("expected weather-edge.apple.com to match")
	}
	if !IsKnownAppleBackgroundHost("gateway.icloud.com") {
		t.Fatal("expected gateway.icloud.com to match")
	}
	if !IsKnownAppleBackgroundHost("news-edge.apple.com") {
		t.Fatal("expected news-edge.apple.com to match")
	}
	if !IsKnownAppleBackgroundHost("c.apple.news") {
		t.Fatal("expected apple.news suffix host to match")
	}
	if IsKnownAppleBackgroundHost("api.apple.com") {
		t.Fatal("did not expect unrelated Apple host to match")
	}
}

func TestShouldSuppressTerminalPassthrough(t *testing.T) {
	t.Parallel()

	if !ShouldSuppressTerminalPassthrough(
		"weatherkit.apple.com",
		errors.New("read tcp 1.2.3.4:443: read: connection reset by peer"),
	) {
		t.Fatal("expected known Apple background reset to be terminal-suppressed")
	}
	if !ShouldSuppressTerminalPassthrough(
		"api-glb-aeun1a.smoot.apple.com",
		errors.New("read tcp: operation timed out"),
	) {
		t.Fatal("expected known Apple background timeout to be terminal-suppressed")
	}
	if !ShouldSuppressTerminalPassthrough(
		"gateway.icloud.com",
		errors.New("read tcp 1.2.3.4:443: read: connection reset by peer"),
	) {
		t.Fatal("expected gateway.icloud.com reset to be terminal-suppressed")
	}
	if !ShouldSuppressTerminalPassthrough(
		"c.apple.news",
		errors.New("read tcp 1.2.3.4:443: read: connection reset by peer"),
	) {
		t.Fatal("expected apple.news reset to be terminal-suppressed")
	}
	if ShouldSuppressTerminalPassthrough(
		"api.apple.com",
		errors.New("read tcp 1.2.3.4:443: read: connection reset by peer"),
	) {
		t.Fatal("did not expect unrelated Apple host to be terminal-suppressed")
	}
}

func TestFormatTarget(t *testing.T) {
	t.Parallel()

	got := FormatTarget("bag.itunes.apple.com", "151.101.3.6:443")
	if got != "bag.itunes.apple.com (151.101.3.6:443)" {
		t.Fatalf("unexpected formatted target %q", got)
	}

	got = FormatTarget("", "151.101.3.6:443")
	if got != "151.101.3.6:443" {
		t.Fatalf("unexpected raw target %q", got)
	}
}

type timeoutError struct{}

func (timeoutError) Error() string   { return "i/o timeout" }
func (timeoutError) Timeout() bool   { return true }
func (timeoutError) Temporary() bool { return false }

var _ net.Error = timeoutError{}
