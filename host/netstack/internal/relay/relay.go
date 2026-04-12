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

// ShouldSuppressTerminalPassthrough reports whether a passthrough relay error
// is low-value operator noise that should stay in diagnostics but stay out of
// the live terminal stream.
func ShouldSuppressTerminalPassthrough(hostname string, err error) bool {
	if !IsKnownAppleBackgroundHost(hostname) {
		return false
	}

	return IsTimeout(err) || IsCloseLike(err)
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

// IsTimeout reports whether err is a network timeout.
func IsTimeout(err error) bool {
	if err == nil {
		return false
	}

	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return true
	}

	return strings.Contains(strings.ToLower(err.Error()), "timed out")
}

// IsKnownAppleBackgroundHost reports whether hostname is one of the known
// guest background Apple endpoints that frequently fail without affecting
// foreground agent workflows.
func IsKnownAppleBackgroundHost(hostname string) bool {
	hostname = normalizeHost(hostname)
	if _, ok := knownAppleBackgroundHosts()[hostname]; ok {
		return true
	}

	for _, suffix := range knownAppleBackgroundHostSuffixes() {
		if strings.HasSuffix(hostname, suffix) {
			return true
		}
	}

	return false
}

func knownAppleBackgroundHosts() map[string]struct{} {
	return map[string]struct{}{
		"bag.itunes.apple.com":   {},
		"courier.push.apple.com": {},
		"gateway.icloud.com":     {},
		"gdmf.apple.com":         {},
		"news-edge.apple.com":    {},
		"ocsp2.apple.com":        {},
		"weather-edge.apple.com": {},
		"weatherkit.apple.com":   {},
	}
}

func knownAppleBackgroundHostSuffixes() []string {
	return []string{
		".apple.news",
		".smoot.apple.com",
	}
}

func normalizeHost(hostname string) string {
	hostname = strings.ToLower(strings.TrimSpace(hostname))
	return strings.TrimRight(hostname, ".")
}

// FormatTarget prefers hostname plus socket address when both are known.
func FormatTarget(hostname, address string) string {
	hostname = strings.TrimSpace(hostname)
	if hostname == "" || hostname == address {
		return address
	}

	return fmt.Sprintf("%s (%s)", hostname, address)
}
