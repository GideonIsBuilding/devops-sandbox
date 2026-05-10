"""
platform/api.py — Control API for DevOps Sandbox Platform
Wraps the bash scripts and exposes 6 REST endpoints.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ── Paths (resolve relative to this file's location) ─────────────────────────
BASE_DIR   = Path(__file__).parent.parent.resolve()
ENVS_DIR   = BASE_DIR / "envs"
LOGS_DIR   = BASE_DIR / "logs"
SCRIPTS    = BASE_DIR / "platform"

ENVS_DIR.mkdir(parents=True, exist_ok=True)
LOGS_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(
    title="DevOps Sandbox Platform API",
    version="1.0.0",
    description="Self-service API for spinning up isolated sandbox environments.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Models ────────────────────────────────────────────────────────────────────
class CreateEnvRequest(BaseModel):
    name: str = "sandbox"
    ttl: int = 1800  # seconds


class OutageRequest(BaseModel):
    mode: str  # crash | pause | network | recover | stress


# ── Helpers ───────────────────────────────────────────────────────────────────
def _run_script(cmd: list[str], timeout: int = 60) -> dict:
    """Run a platform script and return stdout/stderr."""
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=str(BASE_DIR),
    )
    return {
        "stdout": result.stdout,
        "stderr": result.stderr,
        "returncode": result.returncode,
    }


def _load_state(env_id: str) -> dict:
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        raise HTTPException(status_code=404, detail=f"Environment not found: {env_id}")
    with open(state_file) as f:
        return json.load(f)


def _list_envs() -> list[dict]:
    envs = []
    now = int(time.time())
    for state_file in sorted(ENVS_DIR.glob("*.json")):
        try:
            with open(state_file) as f:
                data = json.load(f)
            data["ttl_remaining"] = max(0, data.get("expires_at", 0) - now)
            envs.append(data)
        except Exception:
            continue
    return envs


# ── Endpoints ─────────────────────────────────────────────────────────────────
@app.get("/")
def root():
    return {
        "service": "DevOps Sandbox Platform",
        "version": "1.0.0",
        "active_envs": len(list(ENVS_DIR.glob("*.json"))),
        "docs": "/docs",
    }


@app.post("/envs", status_code=201)
def create_env(req: CreateEnvRequest):
    """Spin up a new isolated sandbox environment."""
    result = _run_script(
        ["bash", str(SCRIPTS / "create_env.sh"), req.name, str(req.ttl)],
        timeout=120,
    )
    if result["returncode"] != 0:
        raise HTTPException(
            status_code=500,
            detail={"error": "Failed to create environment", "stderr": result["stderr"]},
        )
    # Return the state of the newly created env
    envs = _list_envs()
    # Find the most recently created
    envs_sorted = sorted(envs, key=lambda e: e.get("created_at", 0), reverse=True)
    latest = envs_sorted[0] if envs_sorted else {}
    return {
        "message": "Environment created",
        "env": latest,
        "output": result["stdout"],
    }


@app.get("/envs")
def list_envs():
    """List all active environments with TTL remaining."""
    envs = _list_envs()
    return {"count": len(envs), "envs": envs}


@app.delete("/envs/{env_id}")
def destroy_env(env_id: str):
    """Destroy a specific environment immediately."""
    _load_state(env_id)  # will 404 if not found
    result = _run_script(
        ["bash", str(SCRIPTS / "destroy_env.sh"), env_id],
        timeout=60,
    )
    if result["returncode"] != 0:
        raise HTTPException(
            status_code=500,
            detail={"error": "Failed to destroy environment", "stderr": result["stderr"]},
        )
    return {"message": f"Environment {env_id} destroyed", "output": result["stdout"]}


@app.get("/envs/{env_id}/logs")
def get_logs(env_id: str, lines: int = Query(default=100, le=1000)):
    """Return the last N lines from the environment's app.log."""
    _load_state(env_id)  # 404 guard
    log_file = LOGS_DIR / env_id / "app.log"
    archived = LOGS_DIR / "archived"

    if not log_file.exists():
        # Check archives
        archives = sorted(archived.glob(f"{env_id}-*/app.log")) if archived.exists() else []
        if archives:
            log_file = archives[-1]
        else:
            return {"env_id": env_id, "lines": [], "note": "No logs found yet."}

    # Tail N lines efficiently
    result = subprocess.run(
        ["tail", f"-{lines}", str(log_file)],
        capture_output=True, text=True,
    )
    log_lines = result.stdout.splitlines()
    return {"env_id": env_id, "log_file": str(log_file), "lines": log_lines}


@app.get("/envs/{env_id}/health")
def get_health(env_id: str, results: int = Query(default=10, le=100)):
    """Return the last N health check results for an environment."""
    _load_state(env_id)
    health_log = LOGS_DIR / env_id / "health.log"

    if not health_log.exists():
        return {"env_id": env_id, "checks": [], "note": "No health data yet — monitor may not have run."}

    proc = subprocess.run(
        ["tail", f"-{results}", str(health_log)],
        capture_output=True, text=True,
    )
    checks = []
    for line in proc.stdout.splitlines():
        try:
            checks.append(json.loads(line))
        except json.JSONDecodeError:
            checks.append({"raw": line})

    return {"env_id": env_id, "checks": checks}


@app.post("/envs/{env_id}/outage")
def simulate_outage(env_id: str, req: OutageRequest):
    """Trigger an outage simulation on an environment."""
    _load_state(env_id)
    valid_modes = {"crash", "pause", "network", "recover", "stress"}
    if req.mode not in valid_modes:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid mode '{req.mode}'. Valid modes: {sorted(valid_modes)}",
        )
    result = _run_script(
        ["bash", str(SCRIPTS / "simulate_outage.sh"), "--env", env_id, "--mode", req.mode],
        timeout=30,
    )
    if result["returncode"] != 0:
        raise HTTPException(
            status_code=500,
            detail={"error": "Simulation failed", "stderr": result["stderr"]},
        )
    return {
        "message": f"Outage simulation [{req.mode}] triggered on {env_id}",
        "output": result["stdout"],
    }


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("API_PORT", 5000))
    uvicorn.run("api:app", host="0.0.0.0", port=port, reload=False)
