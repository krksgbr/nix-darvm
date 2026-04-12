#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/scripts/harness-common.sh"

dvm_core="$repo_root/build/swift/debug/dvm-core"
dvm_netstack="$repo_root/build/dvm-netstack"
dvm_wrapper_cmd=(env DVM_CORE="$dvm_core" DVM_NETSTACK="$dvm_netstack" nix run --impure .#dvm --)
fixture_src="$repo_root/scripts/fixtures/nix-direnv-regression"
tmp_parent="$HOME/projects"
tmp_root="$(mktemp -d "$tmp_parent/dvm-nix-direnv-regression.XXXXXX")"
fixture_dir="$tmp_root/fixture"
timeout_runner_script="$tmp_root/guest-run-with-timeout.sh"
timeout_repro_script="$tmp_root/guest-timeout-repro.sh"
start_log="$tmp_root/dvm-start.log"

vm_name=""
start_pid=""
verbose=0
debug=0
keep_tmp=0
log_tail_pid=""

if [[ -t 1 ]]; then
  color_step=$'\033[1;34m'
  color_info=$'\033[0;36m'
  color_pass=$'\033[0;32m'
  color_fail=$'\033[0;31m'
  color_reset=$'\033[0m'
else
  color_step=""
  color_info=""
  color_pass=""
  color_fail=""
  color_reset=""
fi

usage() {
  cat <<'EOF'
Usage: test-nix-direnv-regression.sh [--verbose] [--debug]

VM-backed regression test for DVM's local Nix cache and nix/direnv bridge behavior.

Asserts:
  1. built_in_mounts does not include nix-cache
  2. ~/.cache/nix is guest-local (directory, not symlink)
  3. nix store info / nix eval succeed in the fixture project
  4. fresh direnv rebuild succeeds
  5. dvm switch preserves the contract
  6. repeated interrupted fresh direnv runs do not poison the daemon bridge

Options:
  --verbose  Stream the live dvm-core start log during boot.
  --debug    Preserve temp artifacts and print extra command context.
EOF
}

while (($# > 0)); do
  case "$1" in
    --verbose)
      verbose=1
      ;;
    --debug)
      debug=1
      keep_tmp=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '%sUnsupported flag:%s %s\n' "$color_fail" "$color_reset" "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

log_step() {
  printf '%sSTEP%s %s\n' "$color_step" "$color_reset" "$1"
}

log_info() {
  printf '%sINFO%s %s\n' "$color_info" "$color_reset" "$1"
}

pass() {
  printf '%sPASS%s %s\n' "$color_pass" "$color_reset" "$1"
}

fail() {
  local name="$1"
  local message="$2"
  printf '%sFAIL%s %s: %s\n' "$color_fail" "$color_reset" "$name" "$message" >&2
  if [[ -f "$start_log" ]]; then
    log_info "Last 60 lines of start log:" >&2
    tail -n 60 "$start_log" >&2 || true
    printf 'Start log: %s\n' "$start_log" >&2
  fi
  exit 1
}

cleanup() {
  local exit_code=$?
  set +e

  if [[ -n "${log_tail_pid:-}" ]]; then
    kill "$log_tail_pid" >/dev/null 2>&1 || true
    wait "$log_tail_pid" >/dev/null 2>&1 || true
    log_tail_pid=""
  fi

  if [[ -n "${start_pid:-}" ]]; then
    "$dvm_core" stop >/dev/null 2>&1 || true
    wait "$start_pid" >/dev/null 2>&1 || true
    start_pid=""
  else
    "$dvm_core" stop >/dev/null 2>&1 || true
  fi

  if [[ "$keep_tmp" -eq 1 ]]; then
    log_info "Preserving temp directory: $tmp_root"
  else
    rm -rf "$tmp_root"
  fi

  exit "$exit_code"
}

trap cleanup EXIT

require_tool() {
  local tool="$1"
  harness_require_tool "$tool" || fail preflight "missing required host tool: $tool"
}

run_from_tmp() {
  harness_run_from_tmp "$@"
}

ensure_binary() {
  harness_ensure_binary "$@"
}

discover_vm_name() {
  harness_discover_vm_name
}

wait_for_running() {
  local status=0
  harness_wait_for_running "$dvm_core" "${start_pid:-}" 180 "$verbose" log_info "Waiting for VM to reach running state..." || status=$?
  case "$status" in
    0) return ;;
    1) fail vm_start "dvm-core start exited before the VM reached running state" ;;
    2) fail vm_start "timed out waiting for VM to reach running state" ;;
    *) fail vm_start "failed to determine VM running state" ;;
  esac
}

start_vm() {
  log_step "boot vm"
  harness_start_vm start_pid "$dvm_core" "$vm_name" "$start_log" "$dvm_netstack"
  if [[ "$verbose" -eq 1 ]]; then
    log_info "Streaming start log: $start_log"
    tail -n +1 -f "$start_log" &
    log_tail_pid=$!
  else
    log_info "Boot log: $start_log"
  fi
  wait_for_running
  if [[ -n "${log_tail_pid:-}" ]]; then
    kill "$log_tail_pid" >/dev/null 2>&1 || true
    wait "$log_tail_pid" >/dev/null 2>&1 || true
    log_tail_pid=""
  fi
}

guest_exec() {
  local command="$1"
  [[ "$debug" -eq 1 ]] && log_info "Guest command: $command"
  run_from_tmp "$dvm_core" exec --no-credentials -- /bin/bash -lc "$command"
}

assert_status_has_no_nix_cache() {
  local status_json="$1"
  python3 - "$status_json" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
mounts = payload.get("built_in_mounts", [])
if not any("[nix-store]" in item for item in mounts):
    raise SystemExit("missing nix-store built-in mount")
if any("nix-cache" in item for item in mounts):
    raise SystemExit("unexpected nix-cache built-in mount present")
PY
}

assert_guest_local_cache() {
  local output
  if ! output="$(guest_exec "ls -ld ~/.cache ~/.cache/nix && if [ -L ~/.cache/nix ]; then echo symlink:\$(readlink ~/.cache/nix); else echo no-symlink; fi")"; then
    fail guest_local_cache "failed to inspect guest cache directory"
  fi
  [[ "$output" == *"/Users/admin/.cache/nix"* ]] || fail guest_local_cache "missing /Users/admin/.cache/nix directory in output"
  [[ "$output" == *"no-symlink"* ]] || fail guest_local_cache "/Users/admin/.cache/nix is still a symlink"
  pass guest_local_cache
}

assert_fixture_nix_health() {
  if ! guest_exec "cd '$fixture_dir' && '$timeout_runner_script' 20 nix store info --store daemon >/dev/null && '$timeout_runner_script' 45 nix eval .#devShells.aarch64-darwin.default.drvPath >/dev/null"; then
    fail fixture_nix_health "nix daemon health or fixture eval failed"
  fi
  pass fixture_nix_health
}

assert_fresh_direnv_rebuild() {
  if ! guest_exec "cd '$fixture_dir' && rm -f .direnv/flake-profile-* .direnv/flake-profile-*.rc .direnv/flake-tmp-profile.* .direnv/flake-tmp-profile.*-link && '$timeout_runner_script' 90 direnv exec . bash -lc true >/dev/null"; then
    fail fresh_direnv_rebuild "fresh direnv rebuild failed"
  fi
  pass fresh_direnv_rebuild
}

write_timeout_helpers() {
  cat >"$timeout_runner_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
seconds="$1"
shift
exec /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' "$seconds" "$@"
EOF
  chmod 755 "$timeout_runner_script"

  cat >"$timeout_repro_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd '$fixture_dir'
for i in 1 2 3; do
  dir="/tmp/dvm-direnv-abort-\$i"
  log="/tmp/dvm-direnv-abort-\$i.log"
  rm -rf "\$dir" "\$log"
  mkdir -p "\$dir"
  echo "--- abort pass \$i ---"
  if ! '$timeout_runner_script' 2 env direnv_layout_dir="\$dir" direnv exec . bash -lc true >"\$log" 2>&1; then
    true
  fi
  cat "\$log"
  if grep -q 'Falling back to previous environment!' "\$log"; then
    echo "direnv fell back to a previous environment during abort pass \$i" >&2
    exit 1
  fi
  if grep -q 'is not tracked by Git' "\$log"; then
    echo "fixture path was treated as an untracked git flake during abort pass \$i" >&2
    exit 1
  fi
  if ! grep -q 'direnv: using flake' "\$log"; then
    echo "abort pass \$i did not reach the intended direnv flake path" >&2
    exit 1
  fi
  '$timeout_runner_script' 15 nix store info --store daemon >/dev/null
  echo "daemon-check-\$i=ok"
done
fd_count="\$(pgrep -fo 'darvm-agent --run-bridge' | xargs -I{} sudo lsof -nP -a -p {} | egrep 'vsock|/tmp/nix-daemon.sock' | wc -l | tr -d ' ')"
echo "bridge-fd-count=\$fd_count"
if (( fd_count > 3 )); then
  echo "bridge fd count unexpectedly high: \$fd_count" >&2
  exit 1
fi
EOF
  chmod 755 "$timeout_repro_script"
}

assert_abort_repro_stays_healthy() {
  local output
  if ! output="$(run_from_tmp "$dvm_core" exec --no-credentials -- "$timeout_repro_script")"; then
    fail abort_repro "repeated interrupted direnv repro failed"
  fi
  [[ "$output" == *"daemon-check-3=ok"* ]] || fail abort_repro "daemon health checks did not complete"
  [[ "$output" == *"bridge-fd-count="* ]] || fail abort_repro "missing bridge fd count output"
  pass abort_repro
}

require_tool tart
require_tool just
require_tool python3

[[ -d "$tmp_parent" ]] || fail preflight "mounted host temp parent missing: $tmp_parent"

log_step "preflight"
ensure_binary "$dvm_core" "just build" "harness_dvm_core_has_virtualization_entitlement \"$dvm_core\""
ensure_binary "$dvm_netstack" "just build-netstack"

if ! vm_name="$(discover_vm_name)"; then
  fail preflight "no darvm-* VM found; run 'just init' first"
fi

if "$dvm_core" status --json >/dev/null 2>&1; then
  fail preflight "VM is already running; stop it before running this regression"
fi

mkdir -p "$fixture_dir"
cp -R "$fixture_src"/. "$fixture_dir"
write_timeout_helpers

start_vm

log_step "assert built-in mounts"
status_json="$($dvm_core status --json)" || fail status "failed to read dvm status"
if ! assert_status_has_no_nix_cache "$status_json"; then
  fail status "unexpected built_in_mounts: $status_json"
fi
pass status

log_step "assert guest-local nix cache"
assert_guest_local_cache

log_step "assert fixture nix health"
assert_fixture_nix_health

log_step "assert fresh direnv rebuild"
assert_fresh_direnv_rebuild

log_step "switch running vm"
(
  cd "$repo_root"
  "${dvm_wrapper_cmd[@]}" switch >/dev/null
) || fail switch "dvm switch failed"
pass switch

log_step "re-check guest-local nix cache after switch"
assert_guest_local_cache

log_step "assert interrupted direnv runs do not poison bridge"
assert_abort_repro_stays_healthy

pass "nix-direnv regression complete"
