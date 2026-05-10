#!/usr/bin/env python3
"""Print health summary for all active environments."""
import json
import time
from pathlib import Path

envs_dir = Path("envs")
logs_dir = Path("logs")
files = sorted(envs_dir.glob("*.json")) if envs_dir.exists() else []

if not files:
    print("  No active environments.")
else:
    for f in files:
        try:
            d = json.loads(f.read_text())
            env_id = d["id"]
            status = d.get("status", "unknown")
            health_log = logs_dir / env_id / "health.log"
            last_check = "no data yet"
            if health_log.exists():
                lines = health_log.read_text().strip().splitlines()
                if lines:
                    rec = json.loads(lines[-1])
                    ok = "✅" if rec.get("healthy") else "❌"
                    last_check = (
                        f"{ok} HTTP {rec.get('status_code','?')} "
                        f"@ {rec.get('latency_ms','?')}ms "
                        f"[{rec.get('timestamp','')}]"
                    )
            print(f"  {env_id}  [{status}]")
            print(f"    Last check: {last_check}")
            print()
        except Exception:
            pass
