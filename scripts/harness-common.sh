#!/usr/bin/env bash
set -euo pipefail

harness_require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || return 1
}

harness_run_from_tmp() {
  (
    cd /tmp
    "$@"
  )
}

harness_dvm_core_has_virtualization_entitlement() {
  local path="$1"
  codesign -d --entitlements :- "$path" 2>/dev/null | grep -q "com.apple.security.virtualization"
}

harness_ensure_binary() {
  local path="$1"
  local build_cmd="$2"
  local validator="${3:-}"

  # shellcheck disable=SC2154 # repo_root is provided by the calling harness script.
  if [[ ! -x "$path" ]]; then
    (cd "$repo_root" && eval "$build_cmd")
    return
  fi

  if [[ -n "$validator" ]] && ! eval "$validator"; then
    (cd "$repo_root" && eval "$build_cmd")
  fi
}

harness_discover_vm_name() {
  tart list --format json | python3 -c '
import json, sys
vms = json.load(sys.stdin)
names = [vm["Name"] for vm in vms if vm["Name"].startswith("darvm-") and not vm["Name"].endswith("-snap")]
if not names:
    sys.exit(1)
print(names[0])
'
}

harness_wait_for_running() {
  local dvm_core="$1"
  local start_pid="$2"
  local start_timeout="${3:-180}"
  local verbose="${4:-0}"
  local heartbeat_fn="${5:-}"
  local heartbeat_message="${6:-}"

  local deadline=$((SECONDS + start_timeout))
  local next_heartbeat=$((SECONDS + 10))

  while (( SECONDS < deadline )); do
    if [[ -n "$start_pid" ]] && ! kill -0 "$start_pid" 2>/dev/null; then
      return 1
    fi

    if status_json="$($dvm_core status --json 2>/dev/null)"; then
      if python3 - "$status_json" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
sys.exit(0 if payload.get("running") and payload.get("phase") == "running" else 1)
PY
      then
        return 0
      fi
    fi

    if [[ "$verbose" -eq 0 ]] && (( SECONDS >= next_heartbeat )); then
      if [[ -n "$heartbeat_fn" && -n "$heartbeat_message" ]]; then
        "$heartbeat_fn" "$heartbeat_message ${SECONDS}s elapsed"
      elif [[ -n "$heartbeat_message" ]]; then
        printf '%s %ss elapsed\n' "$heartbeat_message" "$SECONDS"
      fi
      next_heartbeat=$((SECONDS + 10))
    fi
    sleep 2
  done

  return 2
}

harness_start_vm() {
  local output_var="$1"
  local dvm_core="$2"
  local vm_name="$3"
  local start_log="$4"
  local dvm_netstack="$5"

  : >"$start_log"
  (
    cd "$repo_root"
    exec env DVM_NETSTACK="$dvm_netstack" "$dvm_core" start --debug --vm-name "$vm_name" >"$start_log" 2>&1
  ) &
  printf -v "$output_var" '%s' "$!"
}
