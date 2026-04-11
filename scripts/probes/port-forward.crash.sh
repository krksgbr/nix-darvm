#!/usr/bin/env bash
# qa:id=port-forward.crash
# qa:description=Stress probe for host auto-port-forward with guest loopback listener
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$repo_root/scripts/repro-port-forward.sh" "$@"
