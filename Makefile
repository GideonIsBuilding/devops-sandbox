SHELL := /bin/bash
.DEFAULT_GOAL := help

CYAN   := \033[36m
GREEN  := \033[32m
YELLOW := \033[33m
RED    := \033[31m
RESET  := \033[0m

-include .env
export

NAME       ?= sandbox
TTL        ?= 1800
API_PORT   ?= 5000
NGINX_PORT ?= 80

.PHONY: help build up down ps create destroy status logs health simulate clean

# ── Help ──────────────────────────────────────────────────────────────
help:
	@printf "\n$(CYAN)╔══════════════════════════════════════════════════════╗$(RESET)\n"
	@printf "$(CYAN)║      DevOps Sandbox Platform — Available Targets     ║$(RESET)\n"
	@printf "$(CYAN)╚══════════════════════════════════════════════════════╝$(RESET)\n\n"
	@printf "$(GREEN)  Infrastructure:$(RESET)\n"
	@printf "  make $(CYAN)build$(RESET)                         Build all Docker images\n"
	@printf "  make $(CYAN)up$(RESET)                            Start Nginx + API + daemon + monitor\n"
	@printf "  make $(CYAN)down$(RESET)                          Stop everything, destroy all envs\n"
	@printf "  make $(CYAN)ps$(RESET)                            Show running platform containers\n\n"
	@printf "$(GREEN)  Environments:$(RESET)\n"
	@printf "  make $(CYAN)create$(RESET) NAME=myapp TTL=300     Create environment\n"
	@printf "  make $(CYAN)destroy$(RESET) ENV=env-abc123        Destroy a specific environment\n"
	@printf "  make $(CYAN)status$(RESET)                        List all active envs + TTL remaining\n\n"
	@printf "$(GREEN)  Observability:$(RESET)\n"
	@printf "  make $(CYAN)logs$(RESET) ENV=env-abc123           Tail environment logs\n"
	@printf "  make $(CYAN)health$(RESET)                        Show all env health statuses\n\n"
	@printf "$(GREEN)  Chaos Engineering:$(RESET)\n"
	@printf "  make $(CYAN)simulate$(RESET) ENV=env-abc123 MODE=crash    Kill container\n"
	@printf "  make $(CYAN)simulate$(RESET) ENV=env-abc123 MODE=pause    Pause container\n"
	@printf "  make $(CYAN)simulate$(RESET) ENV=env-abc123 MODE=network  Network isolate\n"
	@printf "  make $(CYAN)simulate$(RESET) ENV=env-abc123 MODE=recover  Restore env\n"
	@printf "  make $(CYAN)simulate$(RESET) ENV=env-abc123 MODE=stress   CPU stress\n\n"
	@printf "$(GREEN)  Maintenance:$(RESET)\n"
	@printf "  make $(CYAN)clean$(RESET)                         Wipe all state, logs, archives\n\n"

# ── Build ─────────────────────────────────────────────────────────────
build:
	@printf "$(CYAN)Building images...$(RESET)\n"
	docker build -t sandbox-demo-app ./demo-app
	docker compose build api
	@printf "$(GREEN)Images built.$(RESET)\n"

# ── Up ────────────────────────────────────────────────────────────────
up: build
	@printf "$(CYAN)Starting platform services...$(RESET)\n"
	@mkdir -p logs envs nginx/conf.d
	docker compose up -d
	@printf "$(CYAN)Starting cleanup daemon...$(RESET)\n"
	@if [ -f logs/cleanup_daemon.pid ]; then \
		OLD_PID=$$(cat logs/cleanup_daemon.pid); \
		kill "$$OLD_PID" 2>/dev/null || true; \
	fi
	@nohup bash platform/cleanup_daemon.sh > logs/cleanup.log 2>&1 &
	@printf "$(GREEN)Cleanup daemon started$(RESET)\n"
	@printf "$(CYAN)Starting health monitor...$(RESET)\n"
	@if [ -f logs/health_monitor.pid ]; then \
		OLD_PID=$$(cat logs/health_monitor.pid); \
		kill "$$OLD_PID" 2>/dev/null || true; \
	fi
	@nohup python3 monitor/health_monitor.py > logs/health_monitor.log 2>&1 &
	@sleep 2
	@printf "$(GREEN)Health monitor started$(RESET)\n"
	@printf "\n$(GREEN)Platform is up!$(RESET)\n"
	@printf "  Nginx : http://localhost:$(NGINX_PORT)/\n"
	@printf "  API   : http://localhost:$(API_PORT)/docs\n\n"

# ── Down ──────────────────────────────────────────────────────────────
down:
	@printf "$(RED)Tearing down platform...$(RESET)\n"
	@if ls envs/*.json 2>/dev/null | head -1 | grep -q .; then \
		printf "$(YELLOW)Destroying all active environments...$(RESET)\n"; \
		for f in envs/*.json; do \
			ENV_ID=$$(python3 -c "import json; print(json.load(open('$$f'))['id'])" 2>/dev/null || true); \
			[ -n "$$ENV_ID" ] && bash platform/destroy_env.sh "$$ENV_ID" 2>/dev/null || true; \
		done; \
	fi
	@for pidfile in logs/cleanup_daemon.pid logs/health_monitor.pid; do \
		if [ -f "$$pidfile" ]; then \
			PID=$$(cat "$$pidfile"); \
			kill "$$PID" 2>/dev/null && printf "Stopped PID $$PID\n" || true; \
			rm -f "$$pidfile"; \
		fi; \
	done
	docker compose down
	@printf "$(GREEN)Platform stopped.$(RESET)\n"

# ── ps ────────────────────────────────────────────────────────────────
ps:
	docker ps --filter "name=sandbox-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# ── Create ────────────────────────────────────────────────────────────
create:
	bash platform/create_env.sh "$(NAME)" "$(TTL)"

# ── Destroy ───────────────────────────────────────────────────────────
destroy:
	@if [ -z "$(ENV)" ]; then \
		printf "$(RED)Error: ENV is required. Example: make destroy ENV=env-abc123$(RESET)\n"; exit 1; \
	fi
	bash platform/destroy_env.sh "$(ENV)"

# ── Status ────────────────────────────────────────────────────────────
status:
	@printf "$(CYAN)Active environments:$(RESET)\n"
	@python3 platform/status.py

# ── Logs ──────────────────────────────────────────────────────────────
logs:
	@if [ -z "$(ENV)" ]; then \
		printf "$(RED)Error: ENV is required. Example: make logs ENV=env-abc123$(RESET)\n"; exit 1; \
	fi
	@LOG_FILE="logs/$(ENV)/app.log"; \
	if [ -f "$$LOG_FILE" ]; then \
		tail -f "$$LOG_FILE"; \
	else \
		printf "$(RED)No log file at $$LOG_FILE. Checking archives...$(RESET)\n"; \
		find logs/archived -name "app.log" -path "*$(ENV)*" 2>/dev/null | head -1 | xargs -r tail -50; \
	fi

# ── Health ────────────────────────────────────────────────────────────
health:
	@printf "$(CYAN)Environment health summary:$(RESET)\n"
	@python3 platform/health_summary.py

# ── Simulate ──────────────────────────────────────────────────────────
simulate:
	@if [ -z "$(ENV)" ] || [ -z "$(MODE)" ]; then \
		printf "$(RED)Error: ENV and MODE required. Example: make simulate ENV=env-abc123 MODE=crash$(RESET)\n"; exit 1; \
	fi
	bash platform/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

# ── Clean ─────────────────────────────────────────────────────────────
clean:
	@printf "$(RED)This will wipe all state, logs, and archives. Continue? [y/N] $(RESET)"; \
	read confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		rm -rf logs/* envs/*.json nginx/conf.d/*.conf; \
		printf "$(GREEN)Cleaned.$(RESET)\n"; \
	else \
		printf "Aborted.\n"; \
	fi