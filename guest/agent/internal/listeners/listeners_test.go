package listeners

import (
	"slices"
	"testing"
)

func TestParseLsofOutput(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		input string
		want  []uint16
	}{
		{
			name: "ipv4 loopback",
			input: `COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
python3 12345 user    4u  IPv4 0xabc123      0t0  TCP 127.0.0.1:8080 (LISTEN)
`,
			want: []uint16{8080},
		},
		{
			name: "ipv6 loopback",
			input: `COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
node    12345 user    4u  IPv6 0xabc123      0t0  TCP [::1]:3000 (LISTEN)
`,
			want: []uint16{3000},
		},
		{
			name: "wildcard included",
			input: `COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
python3 12345 user    4u  IPv4 0xabc123      0t0  TCP *:5000 (LISTEN)
`,
			want: []uint16{5000},
		},
		{
			name: "non-loopback excluded",
			input: `COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
nginx   12345 user    4u  IPv4 0xabc123      0t0  TCP 192.168.1.1:9090 (LISTEN)
`,
			want: nil,
		},
		{
			name: "duplicates collapsed",
			input: `COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
node    12345 user    4u  IPv4 0xabc123      0t0  TCP 127.0.0.1:3000 (LISTEN)
node    12345 user    5u  IPv6 0xdef456      0t0  TCP [::1]:3000 (LISTEN)
`,
			want: []uint16{3000},
		},
		{
			name: "multiple ports sorted",
			input: `COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
node    12345 user    4u  IPv4 0xabc123      0t0  TCP 127.0.0.1:8080 (LISTEN)
python3 67890 user    4u  IPv4 0xdef456      0t0  TCP *:3000 (LISTEN)
pg      11111 user    4u  IPv4 0xghi789      0t0  TCP 127.0.0.1:5432 (LISTEN)
`,
			want: []uint16{3000, 5432, 8080},
		},
		{
			name:  "empty output",
			input: "",
			want:  nil,
		},
		{
			name: "header only",
			input: `COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
`,
			want: nil,
		},
		{
			name: "malformed lines skipped",
			input: `COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
this is not a valid line
node    12345 user    4u  IPv4 0xabc123      0t0  TCP 127.0.0.1:8080 (LISTEN)
another bad line (LISTEN)
`,
			want: []uint16{8080},
		},
		{
			name: "mixed loopback and non-loopback",
			input: `COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
node    12345 user    4u  IPv4 0xabc123      0t0  TCP 127.0.0.1:3000 (LISTEN)
nginx   67890 user    4u  IPv4 0xdef456      0t0  TCP 10.0.0.1:3000 (LISTEN)
redis   11111 user    4u  IPv4 0xghi789      0t0  TCP *:6379 (LISTEN)
`,
			want: []uint16{3000, 6379},
		},
		{
			name: "established connections ignored",
			input: `COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
node    12345 user    4u  IPv4 0xabc123      0t0  TCP 127.0.0.1:3000 (LISTEN)
node    12345 user    5u  IPv4 0xabc456      0t0  TCP 127.0.0.1:3000->127.0.0.1:54321 (ESTABLISHED)
`,
			want: []uint16{3000},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := ParseLsofOutput(tt.input)
			if !slices.Equal(got, tt.want) {
				t.Errorf("ParseLsofOutput() = %v, want %v", got, tt.want)
			}
		})
	}
}
