#!/usr/bin/env python3
"""
monitor/health_monitor.py — stdlib only, no pip required.
Polls every active env's /health every 30s.
Writes newline-delimited JSON to logs/<env_id>/health.log.
Marks env 'degraded' after 3 consecutive failures.
"""
from __future__ import annotations
import json, os, signal, time, urllib.request, urllib.error
from pathlib import Path

BASE_DIR          = Path(__file__).parent.parent.resolve()
ENVS_DIR          = BASE_DIR / "envs"
LOGS_DIR          = BASE_DIR / "logs"
POLL_INTERVAL     = int(os.environ.get("HEALTH_POLL_INTERVAL", 30))
FAILURE_THRESHOLD = int(os.environ.get("HEALTH_FAILURE_THRESHOLD", 3))
REQUEST_TIMEOUT   = int(os.environ.get("HEALTH_REQUEST_TIMEOUT", 5))

failure_counts: dict[str, int] = {}
running = True

def handle_signal(sig, frame):
    global running; running = False

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT,  handle_signal)

def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)

def load_active_envs():
    envs = []
    for f in sorted(ENVS_DIR.glob("*.json")):
        try:
            d = json.loads(f.read_text())
            if d.get("status") in ("running", "stressed", "degraded"):
                envs.append(d)
        except Exception:
            pass
    return envs

def update_status(env_id, new_status):
    sf = ENVS_DIR / f"{env_id}.json"
    if not sf.exists(): return
    try:
        d = json.loads(sf.read_text())
        d["status"] = new_status
        tmp = sf.with_suffix(".tmp")
        tmp.write_text(json.dumps(d, indent=2))
        tmp.replace(sf)
    except Exception as e:
        log(f"  WARNING: could not update status for {env_id}: {e}")

def poll_env(env):
    env_id     = env["id"]
    health_url = env.get("health_url", f"http://localhost/envs/{env_id}/health")
    record = {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "epoch": int(time.time()), "env_id": env_id, "url": health_url,
              "status_code": None, "latency_ms": None, "healthy": False, "error": None}
    start = time.time()
    try:
        with urllib.request.urlopen(urllib.request.Request(health_url), timeout=REQUEST_TIMEOUT) as r:
            record["status_code"] = r.status
            record["latency_ms"]  = round((time.time()-start)*1000, 1)
            record["healthy"]     = r.status == 200
    except urllib.error.HTTPError as e:
        record["status_code"] = e.code
        record["latency_ms"]  = round((time.time()-start)*1000, 1)
        record["error"]       = f"HTTP {e.code}"
    except urllib.error.URLError as e:
        record["error"] = f"URLError: {e.reason}"
    except Exception as e:
        record["error"] = str(e)
    return record

def write_record(env_id, record):
    d = LOGS_DIR / env_id
    d.mkdir(parents=True, exist_ok=True)
    with open(d / "health.log", "a") as f:
        f.write(json.dumps(record) + "\n")

def run_cycle():
    envs = load_active_envs()
    if not envs:
        log("No active environments."); return
    log(f"Polling {len(envs)} environment(s)...")
    for env in envs:
        env_id = env["id"]
        rec    = poll_env(env)
        write_record(env_id, rec)
        if rec["healthy"]:
            failure_counts[env_id] = 0
            log(f"  OK  {env_id}: HTTP {rec['status_code']} in {rec['latency_ms']}ms")
        else:
            failure_counts[env_id] = failure_counts.get(env_id, 0) + 1
            n = failure_counts[env_id]
            log(f"  FAIL #{n}  {env_id}: {rec.get('error') or rec.get('status_code')}")
            if n >= FAILURE_THRESHOLD and env.get("status") != "degraded":
                log(f"  --> {env_id}: marking DEGRADED")
                update_status(env_id, "degraded")

def main():
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    (LOGS_DIR / "health_monitor.pid").write_text(str(os.getpid()))
    log("="*50)
    log(f"Health monitor started (PID {os.getpid()}), interval={POLL_INTERVAL}s")
    log("="*50)
    while running:
        try: run_cycle()
        except Exception as e: log(f"  ERROR in poll cycle: {e}")
        if running: time.sleep(POLL_INTERVAL)
    log("Health monitor stopped.")

if __name__ == "__main__":
    main()