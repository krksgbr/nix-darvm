#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/harness-common.sh"
dvm_core="$repo_root/build/swift/debug/dvm-core"
dvm_netstack="$repo_root/build/dvm-netstack"
stress_driver="$repo_root/scripts/port-forward-stress.py"
state_dir="$HOME/.local/state/dvm"
config_path="$HOME/.config/dvm/config.toml"
diagnostic_reports_dir="$HOME/Library/Logs/DiagnosticReports"
default_artifacts_root="$repo_root/.tmp-port-forward-repro"

duration=600
workers=8
port=4321
verbose=0
artifacts_root="$default_artifacts_root"
vm_name=""
start_timeout=180
forward_timeout=60
start_pid=""
stress_pid=""
start_exit_code=""
stress_exit_code=""
run_result="unknown"
log_tail_pid=""
run_started_at_epoch="$(date +%s)"
run_started_at_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
run_stamp="$(date +"%Y%m%d-%H%M%S")-port${port}-$$"
run_dir=""
start_log=""
stress_log=""
stress_summary=""
dvm_json_log=""
last_status_json=""
diag_before_file=""
guest_listener_label="com.dvm.port-forward-repro"
guest_listener_lsof=""
guest_listener_launchctl=""
host_probe_log=""
host_proof_log=""

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
Usage: repro-port-forward.sh [options]

Stress the host auto-port-forward path against a guest loopback listener and
collect per-run artifacts in a unique directory.

Options:
  --duration SECONDS        Total wall-clock seconds to keep generating load.
                            Use ~60 for a quick smoke test, 300-600+ for a soak.
                            Default: 600.
  --workers COUNT           Number of concurrent host client loops hammering the
                            forwarded host port. Higher values increase connection
                            churn; this is not a fixed requests/second rate.
                            Default: 8.
  --port PORT               Guest loopback port to open and then hit through the
                            host auto-forwarder. The same port is expected on the
                            host at 127.0.0.1:PORT. It must be free on the host
                            before the run starts and allowed by the current
                            [ports] auto-forward policy. Default: 4321.
  --artifacts-root PATH     Root directory for per-run artifacts
                            (default: ./.tmp-port-forward-repro)
  --vm-name NAME            Tart VM name (default: first darvm-* VM)
  --verbose                 Stream the live dvm start log while the harness runs
  -h, --help                Show this help

Examples:
  just probe run port-forward.crash --duration 60 --workers 4 --port 4321
  just probe run port-forward.crash --duration 600 --workers 16 --port 4321 --verbose

Artifacts are copied into a dedicated run directory plus a stable 'latest'
symlink under the artifacts root so they never get mixed with prior runs.
EOF
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
    --vm-name)
      vm_name="$2"
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
      printf '%sUnsupported flag:%s %s\n' "$color_fail" "$color_reset" "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

run_stamp="$(date +"%Y%m%d-%H%M%S")-port${port}-$$"
run_dir="$artifacts_root/$run_stamp"
start_log="$run_dir/dvm-start.log"
stress_log="$run_dir/stress.log"
stress_summary="$run_dir/stress-summary.json"
diag_before_file="$run_dir/diagnostic-reports.before"
guest_listener_lsof="$run_dir/guest-listener-lsof.txt"
guest_listener_launchctl="$run_dir/guest-listener-launchctl.txt"
host_probe_log="$run_dir/host-forward-probe.txt"
host_proof_log="$run_dir/host-forward-proof.txt"

mkdir -p "$run_dir"
ln -sfn "$run_dir" "$artifacts_root/latest"

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
  if [[ "$run_result" == "unknown" ]]; then
    run_result="failed-${name}"
  fi
  printf '%sFAIL%s %s: %s\n' "$color_fail" "$color_reset" "$name" "$message" >&2
  write_run_info
  printf 'Artifacts: %s\n' "$run_dir" >&2
  exit 1
}

write_run_info() {
  cat >"$run_dir/run-info.txt" <<EOF
run_dir=$run_dir
artifacts_root=$artifacts_root
vm_name=${vm_name:-}
port=$port
workers=$workers
duration_seconds=$duration
run_started_at_epoch=$run_started_at_epoch
run_started_at_iso=$run_started_at_iso
run_result=$run_result
dvm_pid=${start_pid:-}
dvm_exit_code=${start_exit_code:-}
stress_exit_code=${stress_exit_code:-}
dvm_json_log=${dvm_json_log:-}
latest_status_json=${last_status_json:-}
EOF
}

cleanup() {
  local exit_code=$?
  set +e

  if [[ -n "${log_tail_pid:-}" ]]; then
    kill "$log_tail_pid" >/dev/null 2>&1 || true
    wait "$log_tail_pid" >/dev/null 2>&1 || true
    log_tail_pid=""
  fi

  if [[ -n "${start_pid:-}" ]] && kill -0 "$start_pid" >/dev/null 2>&1; then
    log_info "Cleanup: stopping VM and guest listener"
    stop_guest_listener || true
    "$dvm_core" stop >/dev/null 2>&1 || true
    if wait_for_process_exit "$start_pid" "Cleanup: VM shutdown"; then
      [[ -z "${start_exit_code:-}" ]] && start_exit_code=0
    else
      [[ -z "${start_exit_code:-}" ]] && start_exit_code=$?
    fi
  elif [[ -n "${start_pid:-}" && -z "${start_exit_code:-}" ]]; then
    log_info "Cleanup: waiting for dvm-core to exit"
    if wait_for_process_exit "$start_pid" "Cleanup: dvm-core exit"; then
      start_exit_code=0
    else
      start_exit_code=$?
    fi
  fi

  log_info "Cleanup: capturing final status snapshot"
  capture_status_snapshot final
  log_info "Cleanup: collecting artifacts"
  collect_artifacts
  write_run_info
  log_info "Artifacts preserved at: $run_dir"
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

assert_positive_integer() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail preflight "$label must be a positive integer"
  (( value > 0 )) || fail preflight "$label must be greater than zero"
}

assert_duration() {
  python3 - "$1" <<'PY'
import sys
value = float(sys.argv[1])
if value <= 0:
    raise SystemExit(1)
PY
}

check_host_port_free() {
  python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
checks = [
    (socket.AF_INET, ("127.0.0.1", port)),
    (socket.AF_INET6, ("::1", port)),
]
for family, addr in checks:
    sock = socket.socket(family, socket.SOCK_STREAM)
    try:
        sock.bind(addr)
    finally:
        sock.close()
PY
}

capture_status_snapshot() {
  local label="$1"
  local path="$run_dir/status-$label.json"
  if status_json="$("$dvm_core" status --json 2>/dev/null)"; then
    printf '%s\n' "$status_json" >"$path"
    last_status_json="$status_json"
    return 0
  fi
  return 1
}

forward_status_summary() {
  [[ -n "${last_status_json:-}" ]] || return 0
  python3 - "$last_status_json" "$port" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
target_port = int(sys.argv[2])
phase = payload.get("phase") or "unknown"
forwarded = payload.get("forwarded_ports") or []
conflicts = payload.get("port_conflicts") or []
parts = [f"phase={phase}"]
parts.append(
    "forwarded=" + (",".join(str(port) for port in forwarded) if forwarded else "none")
)
parts.append(
    "conflicts=" + (",".join(str(port) for port in conflicts) if conflicts else "none")
)
parts.append(f"target={target_port}")
print(", ".join(parts))
PY
}

wait_for_process_exit() {
  local pid="$1"
  local label="$2"
  local started=$SECONDS
  local next_heartbeat=$((SECONDS + 10))

  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( SECONDS >= next_heartbeat )); then
      log_info "$label still in progress... $((SECONDS - started))s elapsed"
      next_heartbeat=$((SECONDS + 10))
    fi
    sleep 1
  done

  if wait "$pid" >/dev/null 2>&1; then
    return 0
  fi
  return $?
}

wait_for_running() {
  local status=0
  harness_wait_for_running "$dvm_core" "${start_pid:-}" "$start_timeout" "$verbose" log_info "Waiting for VM to reach running state..." || status=$?
  if [[ "$status" == "0" ]]; then
    return
  fi
  if [[ "$status" == "1" && -n "${start_pid:-}" ]] && ! kill -0 "$start_pid" >/dev/null 2>&1; then
    if wait "$start_pid" >/dev/null 2>&1; then
      start_exit_code=0
    else
      start_exit_code=$?
    fi
    run_result="crashed"
    fail vm_start "dvm-core start exited before the VM reached running state (exit=${start_exit_code})"
  fi
  if [[ "$status" == "2" ]]; then
    fail vm_start "timed out waiting for VM to reach running state"
  fi
  fail vm_start "failed to determine VM running state"
}
wait_for_forwarded_port() {
  local deadline=$((SECONDS + forward_timeout))
  local started=$SECONDS
  local next_heartbeat=$((SECONDS + 10))
  log_info "Waiting for host auto-forward of localhost:${port}"

  while (( SECONDS < deadline )); do
    if [[ -n "${start_pid:-}" ]] && ! kill -0 "$start_pid" >/dev/null 2>&1; then
      if wait "$start_pid" >/dev/null 2>&1; then
        start_exit_code=0
      else
        start_exit_code=$?
      fi
      run_result="crashed"
      fail port_forward "dvm-core exited while waiting for port ${port} to publish (exit=${start_exit_code})"
    fi

    if capture_status_snapshot forwarded; then
      if python3 - "$last_status_json" "$port" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
port = int(sys.argv[2])
ports = payload.get("forwarded_ports") or []
sys.exit(0 if port in ports else 1)
PY
      then
        return
      fi
    fi

    if (( SECONDS >= next_heartbeat )); then
      local summary
      summary="$(forward_status_summary 2>/dev/null || true)"
      if [[ -n "$summary" ]]; then
        log_info "Waiting for host auto-forward of localhost:${port}... $((SECONDS - started))s elapsed ($summary)"
      else
        log_info "Waiting for host auto-forward of localhost:${port}... $((SECONDS - started))s elapsed"
      fi
      next_heartbeat=$((SECONDS + 10))
    fi
    sleep 2
  done

  fail port_forward "port ${port} was not auto-forwarded within ${forward_timeout}s; choose an allowed port or check [ports] config"
}

record_existing_diagnostic_reports() {
  if [[ -d "$diagnostic_reports_dir" ]]; then
    find "$diagnostic_reports_dir" -maxdepth 1 -type f -name 'dvm-core-*' | sort >"$diag_before_file"
  else
    : >"$diag_before_file"
  fi
}

copy_new_diagnostic_reports() {
  local destination="$run_dir/diagnostic-reports"
  mkdir -p "$destination"

  python3 - "$diagnostic_reports_dir" "$diag_before_file" "$destination" <<'PY'
import shutil
import sys
from pathlib import Path

source = Path(sys.argv[1])
before_file = Path(sys.argv[2])
destination = Path(sys.argv[3])
seen = set(before_file.read_text().splitlines()) if before_file.exists() else set()
copied = 0
if source.exists():
    for path in sorted(source.glob("dvm-core-*")):
        resolved = str(path)
        if resolved in seen:
            continue
        shutil.copy2(path, destination / path.name)
        copied += 1
print(copied)
PY
}

collect_artifacts() {
  local destination_state="$run_dir/state-dir"
  rm -rf "$destination_state"
  if [[ -d "$state_dir" ]]; then
    cp -R "$state_dir" "$destination_state"
  fi

  if [[ -n "${dvm_json_log:-}" && -f "$dvm_json_log" ]]; then
    cp "$dvm_json_log" "$run_dir/dvm-core.jsonl"
  fi

  if [[ -f "$config_path" ]]; then
    cp "$config_path" "$run_dir/dvm-config.toml"
  fi

  if [[ "$run_result" == "crashed" ]]; then
    log_info "Cleanup: waiting briefly for a new dvm-core crash report to land"
    local copied=0
    local attempt=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      attempt=$((attempt + 1))
      copied="$(copy_new_diagnostic_reports)"
      [[ "$copied" != "0" ]] && break
      if (( attempt == 5 )); then
        log_info "Cleanup: still waiting for a crash report... 10s elapsed"
      fi
      sleep 2
    done
  else
    copy_new_diagnostic_reports >/dev/null
  fi
}

stage_guest_scripts() {
  local repro_dir="$state_dir/port-forward-repro"
  mkdir -p "$repro_dir"

  cat >"$repro_dir/start-listener.sh" <<'EOF'
#!/bin/sh
set -eu
repro_dir=/var/run/dvm-state/port-forward-repro
label=com.dvm.port-forward-repro
pidfile="$repro_dir/guest-listener.pid"
logfile="$repro_dir/guest-listener.log"
stdout_log="$repro_dir/guest-listener.stdout.log"
stderr_log="$repro_dir/guest-listener.stderr.log"
staged_plist="$repro_dir/$label.plist"
installed_plist="/Library/LaunchDaemons/$label.plist"
port="$1"
mkdir -p "$repro_dir"
rm -f "$pidfile" "$logfile" "$stdout_log" "$stderr_log"
command -v nc >/dev/null 2>&1 || {
  echo "guest precondition failed: nc is not installed" >&2
  exit 1
}
command -v launchctl >/dev/null 2>&1 || {
  echo "guest precondition failed: launchctl is not installed" >&2
  exit 1
}
command -v plutil >/dev/null 2>&1 || {
  echo "guest precondition failed: plutil is not installed" >&2
  exit 1
}
command -v install >/dev/null 2>&1 || {
  echo "guest precondition failed: install is not installed" >&2
  exit 1
}
sudo launchctl bootout "system/$label" 2>/dev/null || true
sudo rm -f "$installed_plist"
cat >"$staged_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
      <string>/usr/bin/nc</string>
      <string>-lk</string>
      <string>127.0.0.1</string>
      <string>$port</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$stdout_log</string>
    <key>StandardErrorPath</key>
    <string>$stderr_log</string>
  </dict>
</plist>
PLIST
plutil -lint "$staged_plist" >/dev/null
sudo install -o root -g wheel -m 644 "$staged_plist" "$installed_plist"
sudo launchctl bootstrap system "$installed_plist"
sudo launchctl kickstart -k "system/$label"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if sudo /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN | grep -q "(LISTEN)"; then
    pid="$(sudo launchctl print "system/$label" 2>/dev/null | awk '/^[[:space:]]*pid = / { print $3; exit }')"
    if [ -n "$pid" ]; then
      echo "$pid" >"$pidfile"
    fi
    echo "guest listener label $label on 127.0.0.1:$port"
    exit 0
  fi
  sleep 1
done
sudo launchctl print "system/$label" >"$logfile" 2>&1 || true
echo "guest listener failed to appear in lsof within 10s" >&2
exit 1
EOF

  cat >"$repro_dir/stop-listener.sh" <<'EOF'
#!/bin/sh
set -eu
repro_dir=/var/run/dvm-state/port-forward-repro
label=com.dvm.port-forward-repro
pidfile="$repro_dir/guest-listener.pid"
installed_plist="/Library/LaunchDaemons/$label.plist"
sudo launchctl bootout "system/$label" 2>/dev/null || true
sudo rm -f "$installed_plist"
rm -f "$pidfile"
EOF

  chmod 755 "$repro_dir/start-listener.sh" "$repro_dir/stop-listener.sh"
}

start_vm() {
  log_step "boot vm"
  harness_start_vm start_pid "$dvm_core" "$vm_name" "$start_log" "$dvm_netstack"
  dvm_json_log="/tmp/dvm-${start_pid}.log"
  if [[ "$verbose" -eq 1 ]]; then
    log_info "Streaming start log: $start_log"
    tail -n +1 -f "$start_log" &
    log_tail_pid=$!
  else
    log_info "Start log: $start_log"
  fi
  wait_for_running
  capture_status_snapshot running || true
}
capture_guest_listener_state() {
  run_from_tmp "$dvm_core" exec --no-credentials -- /bin/sh -c "sudo /usr/sbin/lsof -nP -iTCP:${port} -sTCP:LISTEN || true" >"$guest_listener_lsof" 2>&1 || true
  run_from_tmp "$dvm_core" exec --no-credentials -- /bin/sh -c "sudo launchctl print system/${guest_listener_label} 2>&1 || true" >"$guest_listener_launchctl" 2>&1 || true
}

wait_for_guest_listener() {
  local deadline=$((SECONDS + 20))
  local started=$SECONDS
  local next_heartbeat=$((SECONDS + 5))
  log_info "Waiting for guest listener visibility via lsof on localhost:${port}"

  while (( SECONDS < deadline )); do
    capture_guest_listener_state
    if python3 - "$guest_listener_lsof" "$port" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
port = sys.argv[2]
sys.exit(0 if re.search(rf":{port}\s+\(LISTEN\)", text) else 1)
PY
    then
      return
    fi

    if (( SECONDS >= next_heartbeat )); then
      log_info "Waiting for guest listener visibility via lsof on localhost:${port}... $((SECONDS - started))s elapsed"
      next_heartbeat=$((SECONDS + 5))
    fi
    sleep 1
  done

  fail guest_listener "guest listener on port ${port} did not become visible via lsof; see $guest_listener_lsof and $guest_listener_launchctl"
}

wait_for_host_forward_proof() {
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if grep -nE "port-fwd\[[^]]+\]: client connected, forwarding to guest:${port}" "$start_log" >"$host_proof_log"; then
      return
    fi
    sleep 1
  done

  fail proof "host probe did not produce a PortForwarder connection log; see $host_probe_log and $start_log"
}

prove_host_forward_path() {
  log_step "prove host port-forward path"
  log_info "Opening a one-shot host localhost:${port} connection"
  if ! python3 - "$port" >"$host_probe_log" 2>&1 <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), timeout=3.0) as sock:
    sock.settimeout(1.0)
    sock.sendall(b"proof\n")
    try:
        sock.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    try:
        while sock.recv(4096):
            pass
    except (socket.timeout, ConnectionResetError, BrokenPipeError, OSError) as exc:
        print(f"recv={exc.__class__.__name__}: {exc}")
    time.sleep(0.1)
print("host probe connected")
PY
  then
    fail proof "host probe connection to localhost:${port} failed; see $host_probe_log"
  fi
  wait_for_host_forward_proof
  pass "host localhost:${port} exercised PortForwarder"
}

start_guest_listener() {
  log_step "start guest loopback listener"
  stage_guest_scripts
  if ! run_from_tmp "$dvm_core" exec --no-credentials -- /bin/sh /var/run/dvm-state/port-forward-repro/start-listener.sh "$port" >"$run_dir/guest-listener-start.txt" 2>&1; then
    fail guest_listener "failed to start guest loopback listener; see $run_dir/guest-listener-start.txt"
  fi
  log_info "Guest listener started; transcript: $run_dir/guest-listener-start.txt"
  wait_for_guest_listener
  pass "guest listener visible via lsof on localhost:${port}"
  wait_for_forwarded_port
  pass "port ${port} auto-forwarded"
  prove_host_forward_path
}

stop_guest_listener() {
  run_from_tmp "$dvm_core" exec --no-credentials -- /bin/sh /var/run/dvm-state/port-forward-repro/stop-listener.sh >/dev/null 2>&1
}

start_stress() {
  log_step "stress localhost:${port}"
  python3 "$stress_driver" \
    --host 127.0.0.1 \
    --port "$port" \
    --duration "$duration" \
    --workers "$workers" \
    --summary-json "$stress_summary" \
    >"$stress_log" 2>&1 &
  stress_pid=$!
  log_info "Stress log: $stress_log"
}

monitor_run() {
  local started=$SECONDS
  local next_heartbeat=$((SECONDS + 10))
  while true; do
    if [[ -n "${stress_pid:-}" ]] && ! kill -0 "$stress_pid" >/dev/null 2>&1; then
      if wait "$stress_pid" >/dev/null 2>&1; then
        stress_exit_code=0
      else
        stress_exit_code=$?
      fi
      break
    fi

    if [[ -n "${start_pid:-}" ]] && ! kill -0 "$start_pid" >/dev/null 2>&1; then
      if wait "$start_pid" >/dev/null 2>&1; then
        start_exit_code=0
      else
        start_exit_code=$?
      fi
      if [[ -n "${stress_pid:-}" ]] && kill -0 "$stress_pid" >/dev/null 2>&1; then
        kill "$stress_pid" >/dev/null 2>&1 || true
        wait "$stress_pid" >/dev/null 2>&1 || true
      fi
      run_result="crashed"
      fail stress "dvm-core exited unexpectedly during stress (exit=${start_exit_code})"
    fi

    if (( SECONDS >= next_heartbeat )); then
      log_info "Stress run still in progress... $((SECONDS - started))s elapsed (see $stress_log)"
      next_heartbeat=$((SECONDS + 10))
    fi

    sleep 1
  done

  if [[ -n "${start_pid:-}" ]] && ! kill -0 "$start_pid" >/dev/null 2>&1; then
    if wait "$start_pid" >/dev/null 2>&1; then
      start_exit_code=0
    else
      start_exit_code=$?
    fi
    run_result="crashed"
    fail stress "dvm-core exited unexpectedly after stress completed (exit=${start_exit_code})"
  fi

  if [[ "${stress_exit_code:-1}" != "0" ]]; then
    run_result="stress-failed"
    fail stress "load generator failed (exit=${stress_exit_code}); see $stress_log"
  fi

  run_result="completed"
}

require_tool tart
require_tool python3
require_tool just

assert_positive_integer "$workers" "--workers"
assert_positive_integer "$port" "--port"
assert_duration "$duration" || fail preflight "--duration must be greater than zero"

log_step "preflight"
ensure_binary "$dvm_core" "just build" "harness_dvm_core_has_virtualization_entitlement \"$dvm_core\""
ensure_binary "$dvm_netstack" "just build-netstack"
[[ -x "$stress_driver" ]] || fail preflight "stress driver is not executable: $stress_driver"

if [[ -z "$vm_name" ]]; then
  if ! vm_name="$(discover_vm_name)"; then
    fail preflight "no darvm-* VM found; run 'just init' first"
  fi
fi

if "$dvm_core" status --json >/dev/null 2>&1; then
  fail preflight "VM is already running; stop it before running the repro harness"
fi

if ! check_host_port_free; then
  fail preflight "localhost port ${port} is already in use on the host"
fi

record_existing_diagnostic_reports
write_run_info
log_info "Artifacts directory: $run_dir"

start_vm
start_guest_listener
start_stress
monitor_run
capture_status_snapshot post-stress || true
pass "stress run completed without crashing dvm-core"
