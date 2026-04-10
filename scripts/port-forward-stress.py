#!/usr/bin/env python3
import argparse
import json
import random
import socket
import sys
import threading
import time
from collections import Counter
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate short-lived localhost TCP traffic against a forwarded guest port. "
            "Each worker repeatedly opens short-lived connections until the duration expires."
        ),
        epilog=(
            "Examples:\n"
            "  port-forward-stress.py --port 4321 --duration 60 --workers 4 --summary-json /tmp/out.json\n"
            "  port-forward-stress.py --host 127.0.0.1 --port 4321 --duration 600 --workers 16 --summary-json /tmp/out.json"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="Host/IP to connect to. Default: 127.0.0.1.",
    )
    parser.add_argument(
        "--port",
        type=int,
        required=True,
        help=(
            "TCP port to hit on the host. In the full repro harness this should match the guest "
            "loopback listener port that dvm auto-forwards."
        ),
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=600.0,
        help="Total wall-clock seconds to keep generating load. Default: 600.",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=8,
        help=(
            "Number of concurrent client loops. Higher values increase connection churn; "
            "this is not a fixed requests/second rate. Default: 8."
        ),
    )
    parser.add_argument(
        "--socket-timeout",
        type=float,
        default=1.0,
        help="Per-socket timeout in seconds. Default: 1.0.",
    )
    parser.add_argument(
        "--summary-json",
        required=True,
        help="Path to write the final JSON summary.",
    )
    parser.add_argument(
        "--report-interval",
        type=float,
        default=5.0,
        help="How often to print progress lines, in seconds. Default: 5.0.",
    )
    return parser.parse_args()


def classify_error(exc: BaseException) -> str:
    if isinstance(exc, ConnectionRefusedError):
        return "connection_refused"
    if isinstance(exc, TimeoutError) or isinstance(exc, socket.timeout):
        return "timeout"
    if isinstance(exc, BrokenPipeError):
        return "broken_pipe"
    if isinstance(exc, ConnectionResetError):
        return "connection_reset"
    if isinstance(exc, OSError):
        if exc.errno is not None:
            return f"oserror_{exc.errno}"
        return "oserror"
    return exc.__class__.__name__.lower()


def worker(
    worker_id: int,
    host: str,
    port: int,
    socket_timeout: float,
    deadline: float,
    counters: Counter,
    lock: threading.Lock,
) -> None:
    rng = random.Random(worker_id * 7919 + int(deadline * 1000))

    while time.monotonic() < deadline:
        action = rng.randrange(4)
        started = time.monotonic()
        outcome = "success"

        try:
            with socket.create_connection((host, port), timeout=socket_timeout) as sock:
                sock.settimeout(socket_timeout)

                if action == 0:
                    # Connect and close immediately.
                    pass
                elif action == 1:
                    sock.sendall(b"ping\n")
                elif action == 2:
                    sock.sendall(b"half-close\n")
                    try:
                        sock.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    try:
                        while sock.recv(4096):
                            pass
                    except socket.timeout:
                        # The guest listener intentionally does not respond.
                        pass
                else:
                    sock.sendall(rng.randbytes(rng.randint(1, 256)))
                    time.sleep(rng.uniform(0.0, 0.05))
        except BaseException as exc:  # noqa: BLE001 - keep raw failure classes in metrics
            outcome = classify_error(exc)

        elapsed_ms = int((time.monotonic() - started) * 1000)
        with lock:
            counters["attempts"] += 1
            counters[outcome] += 1
            counters["elapsed_ms_total"] += elapsed_ms
            if elapsed_ms > counters["elapsed_ms_max"]:
                counters["elapsed_ms_max"] = elapsed_ms

        if outcome != "success":
            time.sleep(rng.uniform(0.01, 0.05))


def snapshot(counters: Counter) -> dict[str, int]:
    return {key: int(value) for key, value in counters.items()}


def main() -> int:
    args = parse_args()

    summary_path = Path(args.summary_json)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    started_at = time.time()
    deadline = time.monotonic() + args.duration
    counters: Counter = Counter(elapsed_ms_max=0)
    lock = threading.Lock()

    threads = [
        threading.Thread(
            target=worker,
            args=(worker_id, args.host, args.port, args.socket_timeout, deadline, counters, lock),
            daemon=True,
        )
        for worker_id in range(args.workers)
    ]

    for thread in threads:
        thread.start()

    previous_attempts = 0
    while any(thread.is_alive() for thread in threads):
        time.sleep(args.report_interval)
        with lock:
            current = snapshot(counters)
        attempts = current.get("attempts", 0)
        delta = attempts - previous_attempts
        previous_attempts = attempts
        successes = current.get("success", 0)
        print(
            f"[stress] attempts={attempts} (+{delta}) successes={successes} "
            f"refused={current.get('connection_refused', 0)} "
            f"timeouts={current.get('timeout', 0)} resets={current.get('connection_reset', 0)}",
            flush=True,
        )

    for thread in threads:
        thread.join()

    finished_at = time.time()
    with lock:
        final = snapshot(counters)

    attempts = final.get("attempts", 0)
    successes = final.get("success", 0)
    elapsed_seconds = max(finished_at - started_at, 0.001)
    summary = {
        "host": args.host,
        "port": args.port,
        "workers": args.workers,
        "duration_seconds": args.duration,
        "socket_timeout_seconds": args.socket_timeout,
        "started_at_epoch": started_at,
        "finished_at_epoch": finished_at,
        "elapsed_seconds": elapsed_seconds,
        "attempts": attempts,
        "successes": successes,
        "attempt_rate_per_second": attempts / elapsed_seconds,
        "success_rate_per_second": successes / elapsed_seconds,
        "elapsed_ms_total": final.get("elapsed_ms_total", 0),
        "elapsed_ms_max": final.get("elapsed_ms_max", 0),
        "errors": {
            key: value
            for key, value in sorted(final.items())
            if key
            not in {"attempts", "success", "elapsed_ms_total", "elapsed_ms_max"}
            and value
        },
    }

    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(f"[stress] summary: {summary_path}", flush=True)

    if attempts == 0:
        print("[stress] no connection attempts were recorded", file=sys.stderr)
        return 1
    if successes == 0:
        print("[stress] all connection attempts failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
