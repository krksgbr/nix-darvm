#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dvm_core="$repo_root/build/swift/debug/dvm-core"
dvm_netstack="$repo_root/build/dvm-netstack"
state_dir="$HOME/.local/state/dvm"
state_scripts_dir="$state_dir/scripts"
global_env_probe="$state_dir/global-env-probe.sh"
global_http_probe="$state_dir/global-http-probe.sh"
local_http_probe="$state_dir/local-http-probe.sh"
config_dir="$HOME/.config/dvm"
global_manifest="$config_dir/credentials.toml"
httpbin_url="https://httpbin.org/anything"
global_test_secret_name="TEST_GLOBAL_PROXY_SECRET"
global_test_secret_value="global-test-secret"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/dvm-e2e-credentials.XXXXXX")"
start_log="$tmp_root/dvm-start.log"
backup_manifest="$tmp_root/credentials.toml.bak"
local_manifest_dir="$tmp_root/local-project/.dvm"
local_manifest="$local_manifest_dir/credentials.toml"

vm_name=""
start_pid=""
had_global_manifest=0
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
Usage: e2e-credentials.sh [--verbose] [--debug]

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
  case "$name" in
    preflight|vm_start)
      if [[ -f "$start_log" ]]; then
    log_info "Last 40 lines of start log:" >&2
    tail -n 40 "$start_log" >&2 || true
      fi
      ;;
  esac
  if [[ -f "$start_log" ]]; then
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
  else
    "$dvm_core" stop >/dev/null 2>&1 || true
  fi

  if [[ "$had_global_manifest" -eq 1 ]]; then
    mkdir -p "$config_dir"
    mv "$backup_manifest" "$global_manifest"
  else
    rm -f "$global_manifest"
  fi

  rm -f "$global_env_probe" "$global_http_probe" "$local_http_probe"

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
  command -v "$tool" >/dev/null 2>&1 || fail preflight "missing required host tool: $tool"
}

run_from_tmp() {
  (
    cd /tmp
    "$@"
  )
}

ensure_binary() {
  local path="$1"
  local build_cmd="$2"
  if [[ ! -x "$path" ]]; then
    (cd "$repo_root" && eval "$build_cmd")
  fi
}

discover_vm_name() {
  tart list --format json | python3 -c '
import json, sys
vms = json.load(sys.stdin)
names = [vm["Name"] for vm in vms if vm["Name"].startswith("darvm-") and not vm["Name"].endswith("-snap")]
if not names:
    sys.exit(1)
print(names[0])
'
}

wait_for_running() {
  local deadline=$((SECONDS + 180))
  local next_heartbeat=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if [[ -n "${start_pid:-}" ]] && ! kill -0 "$start_pid" 2>/dev/null; then
      fail vm_start "dvm-core start exited before the VM reached running state"
    fi

    if status_json="$("$dvm_core" status --json 2>/dev/null)"; then
      if python3 - "$status_json" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
sys.exit(0 if payload.get("running") and payload.get("phase") == "running" else 1)
PY
      then
        return
      fi
    fi

    if [[ "$verbose" -eq 0 ]] && (( SECONDS >= next_heartbeat )); then
      log_info "Waiting for VM to reach running state... ${SECONDS}s elapsed"
      next_heartbeat=$((SECONDS + 10))
    fi
    sleep 2
  done

  fail vm_start "timed out waiting for VM to reach running state"
}

start_vm() {
  log_step "boot vm"
  : >"$start_log"
  (
    cd "$repo_root"
    DVM_NETSTACK="$dvm_netstack" "$dvm_core" start --debug --vm-name "$vm_name" >"$start_log" 2>&1
  ) &
  start_pid=$!
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

stop_vm() {
  log_step "stop vm"
  "$dvm_core" stop >/dev/null
  wait "$start_pid" >/dev/null 2>&1 || true
  start_pid=""
}

guest_boot_scripts_are_current() {
  run_from_tmp "$dvm_core" exec --no-credentials -- /bin/sh -lc \
    'cmp -s /usr/local/bin/dvm-activator /var/run/dvm-state/scripts/dvm-activator && cmp -s /usr/local/bin/dvm-mount-store /var/run/dvm-state/scripts/dvm-mount-store'
}

guest_has_legacy_global_env_copy() {
  run_from_tmp "$dvm_core" exec --no-credentials -- /bin/sh -lc 'test -e /etc/dvm-global-credentials.env'
}

assert_guest_command() {
  local name="$1"
  local command="$2"
  [[ "$debug" -eq 1 ]] && log_info "Guest assertion command: $command"
  if run_from_tmp "$dvm_core" exec --no-credentials -- /bin/sh -lc "$command" >/dev/null; then
    pass "$name"
  else
    fail "$name" "guest command failed: $command"
  fi
}

assert_output_contains() {
  local name="$1"
  local output="$2"
  local expected="$3"
  if [[ "$output" != *"$expected"* ]]; then
    fail "$name" "expected output to contain: $expected"$'\n'"Actual output:"$'\n'"$output"
  fi
}

require_tool tart
require_tool curl
require_tool python3
require_tool just

log_step "preflight"
ensure_binary "$dvm_core" "just build"
ensure_binary "$dvm_netstack" "just build-netstack"

curl -fsS "$httpbin_url" >/dev/null || fail preflight "httpbin.org is unreachable"

if ! vm_name="$(discover_vm_name)"; then
  fail preflight "no darvm-* VM found; run 'just init' first"
fi

if "$dvm_core" status --json >/dev/null 2>&1; then
  fail preflight "VM is already running; stop it before running the e2e harness"
fi

mkdir -p "$config_dir" "$local_manifest_dir" "$state_scripts_dir"
if [[ -f "$global_manifest" ]]; then
  cp "$global_manifest" "$backup_manifest"
  had_global_manifest=1
fi

cat >"$global_manifest" <<'EOF'
version = 0

[proxy.TEST_GLOBAL_PROXY_SECRET]
hosts = ["httpbin.org"]
from.command = ["/bin/echo", "global-test-secret"]
EOF

cat >"$local_manifest" <<'EOF'
version = 0
project = "e2e-credentials"

[proxy.LOCAL_ENV_SECRET]
hosts = ["httpbin.org"]

[proxy.LOCAL_CMD_SECRET]
hosts = ["httpbin.org"]
from.command = ["/bin/echo", "local-command-secret"]
EOF

log_step "write test fixtures"
start_vm

log_step "stage guest boot scripts"
mkdir -p "$state_scripts_dir"
cp "$repo_root/guest/image-minimal/scripts/dvm-activator" "$state_scripts_dir/dvm-activator"
cp "$repo_root/guest/image-minimal/scripts/dvm-mount-store" "$state_scripts_dir/dvm-mount-store"
cat >"$global_env_probe" <<EOF
#!/bin/sh
set -eu
. /var/run/dvm-state/global-credentials.env
test -n "\${$global_test_secret_name}"
EOF
chmod 755 "$global_env_probe"
cat >"$global_http_probe" <<EOF
#!/bin/sh
set -eu
. /var/run/dvm-state/global-credentials.env
curl -fsS $httpbin_url -H "Authorization: Bearer \${$global_test_secret_name}"
EOF
chmod 755 "$global_http_probe"
cat >"$local_http_probe" <<EOF
#!/bin/sh
set -eu
curl -fsS $httpbin_url -H "Authorization: Bearer \$LOCAL_ENV_SECRET" -H "X-Test: \$LOCAL_CMD_SECRET"
EOF
chmod 755 "$local_http_probe"

needs_reboot=0
if ! guest_boot_scripts_are_current; then
  log_info "Guest boot scripts are stale; refreshing installed copies"
  run_from_tmp "$dvm_core" exec --no-credentials -- sudo sh -lc \
    'install -m 755 /var/run/dvm-state/scripts/dvm-activator /usr/local/bin/dvm-activator && install -m 755 /var/run/dvm-state/scripts/dvm-mount-store /usr/local/bin/dvm-mount-store'
  needs_reboot=1
fi

if guest_has_legacy_global_env_copy; then
  log_info "Removing legacy /etc/dvm-global-credentials.env before verification"
  run_from_tmp "$dvm_core" exec --no-credentials -- sudo rm -f /etc/dvm-global-credentials.env
  needs_reboot=1
fi

if [[ "$needs_reboot" -eq 1 ]]; then
  log_step "reboot vm to apply boot-time changes"
  stop_vm
  start_vm
else
  log_info "Guest boot scripts are current; no extra reboot needed"
fi

log_step "run guest assertions"
assert_guest_command "global_env_not_copied_to_etc" 'test ! -e /etc/dvm-global-credentials.env'
assert_guest_command "global_env_present_in_state_mount" 'test -f /var/run/dvm-state/global-credentials.env'
assert_guest_command \
  "global_env_contains_placeholder_only" \
  'grep -q "^export TEST_GLOBAL_PROXY_SECRET=" /var/run/dvm-state/global-credentials.env && grep -q "SANDBOX_CRED_" /var/run/dvm-state/global-credentials.env && ! grep -q "global-test-secret" /var/run/dvm-state/global-credentials.env'
assert_guest_command \
  "global_env_sources_into_shell" \
  '/bin/sh /var/run/dvm-state/global-env-probe.sh'

if ! local_env_output="$(
  cd /tmp &&
    env LOCAL_ENV_SECRET=local-env-secret \
      "$dvm_core" exec --credentials "$local_manifest" -- /usr/bin/env
)"; then
  fail "local_exec_injects_placeholders" "failed to capture guest environment"
fi
assert_output_contains "local_exec_injects_placeholders" "$local_env_output" "LOCAL_ENV_SECRET=SANDBOX_CRED_"
assert_output_contains "local_exec_injects_placeholders" "$local_env_output" "LOCAL_CMD_SECRET=SANDBOX_CRED_"
pass "local_exec_injects_placeholders"

if ! global_probe_output="$(
  run_from_tmp "$dvm_core" exec --no-credentials -- /bin/sh /var/run/dvm-state/global-http-probe.sh
)"; then
  fail "global_https_substitution_works" "guest HTTPS probe failed"
fi
[[ "$debug" -eq 1 ]] && printf '%sDEBUG%s global probe output:\n%s\n' "$color_info" "$color_reset" "$global_probe_output"
assert_output_contains \
  "global_https_substitution_works" \
  "$global_probe_output" \
  "Bearer $global_test_secret_value"
pass "global_https_substitution_works"

if ! local_probe_output="$(
  cd /tmp &&
    env LOCAL_ENV_SECRET=local-env-secret \
      "$dvm_core" exec --credentials "$local_manifest" -- /bin/sh /var/run/dvm-state/local-http-probe.sh
)"; then
  fail "local_https_substitution_works" "guest HTTPS probe failed"
fi
[[ "$debug" -eq 1 ]] && printf '%sDEBUG%s local probe output:\n%s\n' "$color_info" "$color_reset" "$local_probe_output"
assert_output_contains \
  "local_https_substitution_works" \
  "$local_probe_output" \
  "Bearer local-env-secret"
assert_output_contains \
  "local_https_substitution_works" \
  "$local_probe_output" \
  "local-command-secret"
pass "local_https_substitution_works"

printf '%sRESULT%s PASS (7/7)\n' "$color_pass" "$color_reset"
