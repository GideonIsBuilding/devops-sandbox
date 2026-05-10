# DevOps Sandbox Platform

A self-service platform for spinning up isolated temporary environments, deploying apps, simulating outages, monitoring health, and auto-destroying everything on a TTL. Think of it as a miniature internal Heroku with a chaos engineering toggle.

---

## Architecture

```
 ┌──────────────────────────────────────────────────────────────────┐
 │                        Linux VM (Host)                           │
 │                                                                  │
 │   make up                                                        │
 │    ├── docker compose up -d   ──────────────────────────────┐   │
 │    ├── cleanup_daemon.sh (bg)                               │   │
 │    └── health_monitor.py (bg)                               │   │
 │                                                             ▼   │
 │  ┌─────────────────────────────────────────────────────────────┐ │
 │  │               Docker: sandbox-platform network              │ │
 │  │                                                             │ │
 │  │  ┌─────────────────┐    ┌──────────────────────────────┐   │ │
 │  │  │  sandbox-nginx  │    │       sandbox-api            │   │ │
 │  │  │  nginx:alpine   │    │    python:3.11-slim          │   │ │
 │  │  │  port 80        │◄───│    FastAPI / uvicorn         │   │ │
 │  │  │                 │    │    port 5000                 │   │ │
 │  │  │  /api/*         │    │    wraps bash scripts        │   │ │
 │  │  │  /envs/{id}/*   │    │    has docker.sock           │   │ │
 │  │  └────────┬────────┘    └──────────────────────────────┘   │ │
 │  │           │                                                  │ │
 │  │           │ proxy_pass                                       │ │
 │  │           │                                                  │ │
 │  │  ┌────────▼────────┐  ┌─────────────────┐  ┌─────────────┐ │ │
 │  │  │ sandbox-app-    │  │  sandbox-app-   │  │ sandbox-app-│ │ │
 │  │  │ env-abc123      │  │  env-def456     │  │ env-ghi789  │ │ │
 │  │  │ Flask/gunicorn  │  │  Flask/gunicorn │  │  ...        │ │ │
 │  │  │ port 3000       │  │  port 3000      │  │             │ │ │
 │  │  │ GET /health     │  │  GET /health    │  │             │ │ │
 │  │  └────────┬────────┘  └────────┬────────┘  └──────┬──────┘ │ │
 │  │           │                    │                   │         │ │
 │  │           ▼                    ▼                   ▼         │ │
 │  │  sandbox-net-abc123   sandbox-net-def456   sandbox-net-ghi  │ │
 │  │  (per-env isolation)  (per-env isolation)  (per-env iso.)   │ │
 │  └─────────────────────────────────────────────────────────────┘ │
 │                                                                  │
 │   Host filesystem                                                │
 │    ├── envs/<env_id>.json    (state files, gitignored)           │
 │    ├── logs/<env_id>/        (app.log, health.log, gitignored)   │
 │    ├── logs/cleanup.log      (daemon log)                        │
 │    ├── logs/archived/        (destroyed env logs)                │
 │    └── nginx/conf.d/         (auto-generated per-env nginx cfg)  │
 └──────────────────────────────────────────────────────────────────┘

  Request flow:
  Browser → :80 → nginx → /envs/{id}/* → sandbox-app-{id}:3000

  Control flow:
  Client → :5000 → FastAPI → bash scripts → Docker daemon
```

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Docker | 24.x |
| Docker Compose | v2.x (`docker compose`) |
| Python 3 | 3.10+ |
| bash | 4.x |
| make | GNU make |

```bash
# Verify:
docker --version && docker compose version && python3 --version
```

---

## Quick Start — Zero to First Running Env in 5 Commands

```bash
# 1. Clone and enter the repo
git clone https://github.com/gideonisbuilding/devops-sandbox && cd devops-sandbox

# 2. Copy the example config
cp .env.example .env

# 3. Build the demo-app image + start Nginx, API, daemon, monitor
make up

# 4. Create your first environment (30-minute TTL)
make create NAME=hello-world TTL=1800

# 5. Hit the environment (replace env-id with the one printed above)
curl http://localhost/envs/<env-id>/
curl http://localhost/envs/<env-id>/health
```

The platform is live. Open http://localhost/api/docs for the interactive API UI.

---

## Full Demo Walkthrough

### 1 — Create an environment

```bash
make create NAME=my-app TTL=300
# Output:
# ╔══════════════════════════════════════════════════╗
# ║  Environment Created Successfully                ║
# ║  ID:      env-x3f9ab                            ║
# ║  URL:     http://localhost/envs/env-x3f9ab/      ║
# ║  TTL:     300s                                   ║
# ╚══════════════════════════════════════════════════╝
```

### 2 — Deploy / inspect the running app

```bash
curl http://localhost/envs/env-x3f9ab/
# {"message":"Hello from my-app!","env_id":"env-x3f9ab","uptime_seconds":2.4}

curl http://localhost/envs/env-x3f9ab/health
# {"status":"ok","env_id":"env-x3f9ab","uptime_seconds":3.1,"timestamp":...}
```

### 3 — Check health status

```bash
make health
# env-x3f9ab  [running]
#   Last check: ✅ HTTP 200 @ 12ms [2024-01-15T10:30:00Z]
```

### 4 — Simulate an outage

```bash
# Crash the container:
make simulate ENV=env-x3f9ab MODE=crash
# Health monitor flags it as degraded within ~90 seconds.

# Watch health log update:
tail -f logs/env-x3f9ab/health.log
```

### 5 — Observe degraded status

```bash
make status
# ID                   NAME            STATUS           TTL LEFT
# -----------------------------------------------------------------
# env-x3f9ab           my-app          degraded         4m 12s

make health
# env-x3f9ab  [degraded]
#   Last check: ❌ HTTP None @ ?ms [2024-01-15T10:32:00Z]
```

### 6 — Recover

```bash
make simulate ENV=env-x3f9ab MODE=recover
# ✅ Environment env-x3f9ab recovered.
```

### 7 — Check logs

```bash
make logs ENV=env-x3f9ab
# Tails logs/env-x3f9ab/app.log in real time
```

### 8 — Manual destroy (or wait for auto-destroy)

```bash
make destroy ENV=env-x3f9ab
# OR just wait — the cleanup daemon destroys it after 300s automatically.
```

---

## API Reference

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/envs` | Create environment `{"name":"x","ttl":1800}` |
| `GET` | `/envs` | List active envs + TTL remaining |
| `DELETE` | `/envs/:id` | Destroy environment |
| `GET` | `/envs/:id/logs?lines=100` | Last N lines of app.log |
| `GET` | `/envs/:id/health?results=10` | Last N health check results |
| `POST` | `/envs/:id/outage` | Trigger simulation `{"mode":"crash"}` |

Interactive docs: **http://localhost:5000/docs**

### Example API calls

```bash
# Create
curl -X POST http://localhost:5000/envs \
  -H "Content-Type: application/json" \
  -d '{"name":"api-test","ttl":600}'

# List
curl http://localhost:5000/envs | python3 -m json.tool

# Destroy
curl -X DELETE http://localhost:5000/envs/env-abc123

# Trigger outage via API
curl -X POST http://localhost:5000/envs/env-abc123/outage \
  -H "Content-Type: application/json" \
  -d '{"mode":"pause"}'
```

---

## Outage Simulation Modes

| Mode | Effect | Recovery |
|------|--------|----------|
| `crash` | `docker kill` — container exits | `MODE=recover` |
| `pause` | `docker pause` — frozen in place | `MODE=recover` |
| `network` | Disconnects from platform network | `MODE=recover` |
| `recover` | Restores from any of the above | — |
| `stress` | CPU spike via `stress-ng` (60s) | Self-resolves |

A safety guard prevents any simulation from targeting Nginx, the API, or daemon containers.

---

## Makefile Targets

```
make build                      Build the demo-app Docker image
make up                         Start Nginx + API + daemon + monitor
make down                       Stop everything, destroy all envs
make ps                         Show running platform containers
make create NAME=x TTL=600      Create environment (non-interactive)
make destroy ENV=env-abc123     Destroy a specific environment
make status                     List all envs + TTL remaining
make logs ENV=env-abc123        Tail environment app logs
make health                     Show all env health statuses
make simulate ENV=x MODE=crash  Run outage simulation
make clean                      Wipe all state, logs, archives
```

---

## Nginx Dynamic Routing

Nginx runs as a Docker container (`sandbox-nginx`) on the `sandbox-platform` network.

`nginx/nginx.conf` includes `conf.d/*.conf` — each environment gets its own file:

```nginx
# nginx/conf.d/env-abc123.conf  (auto-generated)
location /envs/env-abc123/ {
    proxy_pass http://sandbox-app-env-abc123:3000/;
    ...
}
```

On every `create_env.sh` or `destroy_env.sh`, the file is written/deleted and `docker exec sandbox-nginx nginx -s reload` is called.

**Docker network approach:** All env containers join the `sandbox-platform` bridge network at creation, making them reachable by Nginx via their container name (`sandbox-app-{ENV_ID}:3000`). Each env also gets a dedicated `sandbox-net-{ENV_ID}` network for inter-env isolation (useful when an env has multiple containers).

---

## Log Shipping

This platform uses **Approach A** (simple):

- At creation: `nohup docker logs -f <container> >> logs/<env_id>/app.log &`
- PID saved to `logs/<env_id>/log_shipper.pid`
- At destroy: PID is killed before container removal (no zombie processes)

Query logs with:
```bash
make logs ENV=env-abc123          # tail -f
curl http://localhost:5000/envs/env-abc123/logs  # last 100 lines via API
```

Archived logs live in `logs/archived/<env_id>-<timestamp>/`.

---

## Known Limitations

1. **Single-VM only** — no clustering. The platform network is a local Docker bridge.
2. **Path-based routing** — environments are at `/envs/{id}/`, not subdomains. Apps that hardcode root-relative paths may need `X-Forwarded-Prefix` awareness.
3. **No auth on the API** — suitable for internal/local use. Add an API key middleware for any network-exposed deployment.
4. **Log shipper restarts** — if the host reboots, the `nohup` log shipper processes are lost. Run `make up` to restart.
5. **Prometheus/Grafana** — optional and not included in the base build. The health monitor writes structured JSON to `health.log`; adding a Prometheus exporter is straightforward.
6. **stress mode** — requires `stress-ng` inside the demo-app container (not pre-installed to keep the image small).
