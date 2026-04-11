#!/usr/bin/env bash
# qa:id=port-forward.regression
# qa:description=VM-backed port-forward regression validation for port auto-forward and listener visibility
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$repo_root/scripts/test-port-forward-regression.sh" "$@"
