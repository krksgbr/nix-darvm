// Package relay provides shared helpers for bidirectional passthrough relays.
package relay

import (
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
)

const relayOutcomeCount = 2

// Result captures the terminal outcome of one relay direction.
// Err is nil when the direction completed cleanly (for example due to EOF).
type Result struct {
	Operation string
	Err       error
}

// Bidirectional runs two opposing copy loops and returns their terminal
// outcomes in completion order.
func Bidirectional(
	firstOperation string,
	firstSrc io.Reader,
	firstDst io.Writer,
	secondOperation string,
	secondSrc io.Reader,
	secondDst io.Writer,
	bufferSize int,
) [2]Result {
	results := make(chan Result, relayOutcomeCount)

	go func() {
		results <- copyOneWay(firstOperation, firstSrc, firstDst, bufferSize)
	}()

	results <- copyOneWay(secondOperation, secondSrc, secondDst, bufferSize)

	first := <-results
	second := <-results

	return [2]Result{first, second}
}

func copyOneWay(operation string, src io.Reader, dst io.Writer, bufferSize int) Result {
	var buf []byte
	if bufferSize > 0 {
		buf = make([]byte, bufferSize)
	}

	_, err := io.CopyBuffer(dst, src, buf)
	if errors.Is(err, io.EOF) {
		err = nil
	}

	return Result{Operation: operation, Err: err}
}

// ResultsToLog filters relay outcomes using the default suppression policy:
// keep the first observable relay failure, but suppress close-like follow-on
// errors once the opposite direction has already finished.
func ResultsToLog(results [2]Result) []Result {
	loggable := make([]Result, 0, len(results))
	for i, result := range results {
		if result.Err == nil {
			continue
		}
		if i > 0 && IsCloseLike(result.Err) {
			continue
		}
		loggable = append(loggable, result)
	}

	return loggable
}

// IsCloseLike reports whether err represents expected connection teardown
// noise rather than a setup or protocol failure.
func IsCloseLike(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
		return true
	}

	msg := err.Error()
	return strings.Contains(msg, "connection reset by peer") ||
		strings.Contains(msg, "endpoint is closed") ||
		strings.Contains(msg, "use of closed network connection") ||
		strings.Contains(msg, "broken pipe")
}

// FormatTarget prefers hostname plus socket address when both are known.
func FormatTarget(hostname, address string) string {
	hostname = strings.TrimSpace(hostname)
	if hostname == "" || hostname == address {
		return address
	}

	return fmt.Sprintf("%s (%s)", hostname, address)
}
