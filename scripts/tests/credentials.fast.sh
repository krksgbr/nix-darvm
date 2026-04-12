#!/usr/bin/env bash
# qa:id=credentials.fast
# qa:description=Host-side credential parser and netstack regression checks (fast path)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: credentials.fast.sh [--help]

Run the host-side credential regression suite:

- host Swift tests for manifest parsing and secret resolution
- netstack Go tests for proxy and placeholder replacement behavior

This suite is expected to be fast and side-effect free.
EOF
}

if (($# > 0)); then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unsupported flag: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
swift_sandbox_flag=()
if ! sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  swift_sandbox_flag+=(--disable-sandbox)
fi

(
  cd "$repo_root/host"
  swift test --scratch-path "$repo_root/build/swift" "${swift_sandbox_flag[@]}"
)
(
  cd "$repo_root/host/netstack"
  go test ./...
)
