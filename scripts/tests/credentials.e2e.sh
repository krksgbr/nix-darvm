#!/usr/bin/env bash
# qa:id=credentials.e2e
# qa:description=VM-backed credential injection e2e regression harness
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$repo_root/scripts/e2e-credentials.sh" "$@"
