#!/usr/bin/env python3
"""Print a table of all active environments with TTL remaining."""
import json
import time
from pathlib import Path

envs_dir = Path("envs")
now = int(time.time())
files = sorted(envs_dir.glob("*.json")) if envs_dir.exists() else []

if not files:
    print("  No active environments.")
else:
    print(f"  {'ID':<20} {'NAME':<15} {'STATUS':<16} {'TTL LEFT'}")
    print("  " + "-" * 65)
    for f in files:
        try:
            d = json.loads(f.read_text())
            ttl_left = max(0, d.get("expires_at", 0) - now)
            mins, secs = divmod(ttl_left, 60)
            print(f"  {d['id']:<20} {d['name']:<15} {d.get('status','?'):<16} {mins}m {secs}s")
        except Exception:
            pass
