#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repro_harness="$repo_root/scripts/repro-port-forward.sh"
default_artifacts_root="$repo_root/.tmp-port-forward-regression"

# Keep defaults intentionally small: this is a regression test, not a soak.
duration=5
workers=1
port=""
verbose=0
artifacts_root="$default_artifacts_root"

if [[ -t 1 ]]; then
  color_step=$'\033[1;34m'
  color_info=$'\033[0;36m'
  color_fail=$'\033[0;31m'
  color_reset=$'\033[0m'
else
  color_step=""
  color_info=""
  color_fail=""
  color_reset=""
fi

usage() {
  cat <<'EOF'
Usage: test-port-forward-regression.sh [options]

Run the real VM-backed port-forward regression test. This wrapper selects a free
allowed host port, invokes the repro harness, and passes only if:
  1. the guest listener becomes visible,
  2. the host auto-forwards the port,
  3. a host localhost probe exercises PortForwarder, and
  4. stress completes without crashing dvm-core.

Options:
  --duration SECONDS        Stress duration for the regression check.
                            Default: 5.
  --workers COUNT           Concurrent host client workers.
                            Default: 1.
  --port PORT               Explicit port to test. If omitted, the wrapper picks
                            the first free port from 4321-4330.
  --artifacts-root PATH     Root directory for per-run artifacts.
                            Default: ./.tmp-port-forward-regression
  --verbose                 Stream the live dvm start log.
  -h, --help                Show this help.

Examples:
  just test run port-forward.regression
  just test run port-forward.regression --verbose
  ./scripts/test-port-forward-regression.sh --port 4321 --duration 10
EOF
}

log_step() {
  printf '%sSTEP%s %s\n' "$color_step" "$color_reset" "$1"
}

log_info() {
  printf '%sINFO%s %s\n' "$color_info" "$color_reset" "$1"
}

fail() {
  printf '%sFAIL%s %s\n' "$color_fail" "$color_reset" "$1" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --duration)
      duration="$2"
      shift
      ;;
    --workers)
      workers="$2"
      shift
      ;;
    --port)
      port="$2"
      shift
      ;;
    --artifacts-root)
      artifacts_root="$2"
      shift
      ;;
    --verbose)
      verbose=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unsupported flag: $1"
      ;;
  esac
  shift
done

pick_free_port() {
  python3 - <<'PY'
import socket
import sys

for port in range(4321, 4331):
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", port))
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock:
            sock.bind(("::1", port))
    except OSError:
        continue
    print(port)
    raise SystemExit(0)

raise SystemExit(1)
PY
}

assert_positive_integer() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$label must be a positive integer"
  (( value > 0 )) || fail "$label must be greater than zero"
}

assert_duration() {
  python3 - "$1" <<'PY'
import sys
value = float(sys.argv[1])
if value <= 0:
    raise SystemExit(1)
PY
}

assert_positive_integer "$workers" "--workers"
assert_duration "$duration" || fail "--duration must be greater than zero"
if [[ -n "$port" ]]; then
  assert_positive_integer "$port" "--port"
else
  log_step "select regression port"
  if ! port="$(pick_free_port)"; then
    fail "No free candidate port found in 4321-4330; pass --port explicitly"
  fi
fi

log_info "Selected port: $port"
log_info "Artifacts root: $artifacts_root"

args=(
  --duration "$duration"
  --workers "$workers"
  --port "$port"
  --artifacts-root "$artifacts_root"
)
if [[ "$verbose" -eq 1 ]]; then
  args+=(--verbose)
fi

exec "$repro_harness" "${args[@]}"
