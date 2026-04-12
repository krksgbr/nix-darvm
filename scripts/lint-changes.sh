#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "lint: required tool '$1' is not available; run via 'just lint' or inside 'nix develop'" >&2
    exit 1
  fi
}

nearest_existing_package() {
  local module_root="$1"
  local rel_path="$2"
  local dir
  dir=$(dirname "$rel_path")
  if [[ "$dir" == "." ]]; then
    echo "./..."
    return
  fi

  while [[ "$dir" != "." && ! -d "$module_root/$dir" ]]; do
    dir=$(dirname "$dir")
  done

  if [[ "$dir" == "." ]]; then
    echo "./..."
  else
    echo "./$dir/..."
  fi
}

require_tool jj
require_tool swiftlint
require_tool golangci-lint
require_tool deadnix
require_tool statix

mapfile -t changed_files < <(jj diff -r @ --name-only)

if [[ ${#changed_files[@]} -eq 0 ]]; then
  echo "lint: no files changed in the current changeset"
  exit 0
fi

declare -A netstack_packages=()
declare -A agent_packages=()
unsupported=()
swift_files=()
nix_files=()
lintable_count=0

for path in "${changed_files[@]}"; do
  [[ -n "$path" ]] || continue

  case "$path" in
    host/netstack/*.go|host/netstack/**/*.go)
      package=$(nearest_existing_package "$repo_root/host/netstack" "${path#host/netstack/}")
      netstack_packages["$package"]=1
      lintable_count=$((lintable_count + 1))
      ;;
    guest/agent/*.go|guest/agent/**/*.go)
      package=$(nearest_existing_package "$repo_root/guest/agent" "${path#guest/agent/}")
      agent_packages["$package"]=1
      lintable_count=$((lintable_count + 1))
      ;;
    *.go)
      unsupported+=("$path")
      ;;
    *.swift)
      if [[ -e "$path" ]]; then
        swift_files+=("$path")
      fi
      lintable_count=$((lintable_count + 1))
      ;;
    *.nix)
      if [[ -e "$path" ]]; then
        nix_files+=("$path")
      fi
      lintable_count=$((lintable_count + 1))
      ;;
  esac
done

if [[ ${#unsupported[@]} -gt 0 ]]; then
  printf 'lint: no targeted linter is configured for these changed files:\n' >&2
  printf '  %s\n' "${unsupported[@]}" >&2
  echo "lint: use 'just lint --all' or extend scripts/lint-changes.sh for these paths" >&2
  exit 1
fi

if [[ $lintable_count -eq 0 ]]; then
  echo "lint: no lintable files changed in the current changeset"
  exit 0
fi

if [[ ${#swift_files[@]} -gt 0 ]]; then
  echo "lint: swiftlint on changed Swift files"
  for path in "${swift_files[@]}"; do
    swiftlint lint --strict --quiet --no-cache --path "$path"
  done
fi

if [[ ${#netstack_packages[@]} -gt 0 ]]; then
  echo "lint: golangci-lint on changed host/netstack packages"
  mapfile -t packages < <(printf '%s\n' "${!netstack_packages[@]}" | sort)
  (
    cd host/netstack
    golangci-lint run "${packages[@]}"
  )
fi

if [[ ${#agent_packages[@]} -gt 0 ]]; then
  echo "lint: golangci-lint on changed guest/agent packages"
  mapfile -t packages < <(printf '%s\n' "${!agent_packages[@]}" | sort)
  (
    cd guest/agent
    golangci-lint run "${packages[@]}"
  )
fi

if [[ ${#nix_files[@]} -gt 0 ]]; then
  echo "lint: deadnix/statix on changed Nix files"
  deadnix "${nix_files[@]}"
  statix check "${nix_files[@]}"
fi
