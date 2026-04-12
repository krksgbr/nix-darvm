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
