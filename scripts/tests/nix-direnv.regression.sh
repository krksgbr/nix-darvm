#!/usr/bin/env bash
# qa:id=nix-direnv.regression
# qa:description=VM-backed regression for guest-local nix cache and nix/direnv bridge recovery after interrupted evals
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$repo_root/scripts/test-nix-direnv-regression.sh" "$@"
