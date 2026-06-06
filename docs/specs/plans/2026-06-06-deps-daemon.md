# Deps Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract dep lifecycle management from `bin/dev` into a new `bin/deps start|stop|status` script that manages the k8s stack and OTLP port-forward as a background daemon.

**Architecture:** `bin/deps` owns all shared-dep lifecycle: starting the k8s stack via skaffold, spawning `kubectl port-forward` processes when `OTEL_ENABLED=true`, and tracking port-forward PIDs in `$GIT_COMMON_DIR/rails-llm-pf.pids`. `bin/dev` delegates to `bin/deps start` and becomes Rails-only.

**Tech Stack:** Bash, kubectl, skaffold, nc (netcat for port checks).

**Spec:** `docs/specs/2026-06-06-deps-daemon-design.md`

---

## Task 1: Create `bin/deps` skeleton with helpers and `status` subcommand

**Files:**
- Create: `bin/deps`

- [ ] **Step 1: Create the script with boilerplate, helpers, and `status` subcommand**

Create `bin/deps` with this exact content:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEPS_SKAFFOLD="skaffold.deps.yaml"
GIT_COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
DEPS_LOCK="${GIT_COMMON_DIR%/}/rails-llm-deps.lock"
DEPS_WAIT_SECONDS=240
PF_PIDS_FILE="${GIT_COMMON_DIR%/}/rails-llm-pf.pids"

# ---------------------------------------------------------------------------
# Load .env (DB creds, LLM endpoint, OTEL settings). Optional.
# ---------------------------------------------------------------------------

if [ -f .env ]; then
  set -o allexport
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    export "$line" 2>/dev/null || true
  done < .env
  set +o allexport
fi

OTEL_ENABLED="${OTEL_ENABLED:-false}"
K8S_CONTEXT="${K8S_CONTEXT:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

deps_reachable() {
  nc -z -w 2 localhost 5432 >/dev/null 2>&1 && nc -z -w 2 localhost 6379 >/dev/null 2>&1
}

port_reachable() {
  nc -z -w 1 localhost "$1" >/dev/null 2>&1
}

# PID file: one "name:pid" entry per line.
pf_write_pid() {
  local name="$1" pid="$2"
  if [ -f "$PF_PIDS_FILE" ]; then
    grep -v "^${name}:" "$PF_PIDS_FILE" > "${PF_PIDS_FILE}.tmp" 2>/dev/null || true
    mv "${PF_PIDS_FILE}.tmp" "$PF_PIDS_FILE"
  fi
  echo "${name}:${pid}" >> "$PF_PIDS_FILE"
}

pf_pid_for() {
  local name="$1"
  [ -f "$PF_PIDS_FILE" ] || return 1
  grep "^${name}:" "$PF_PIDS_FILE" | cut -d: -f2
}

pf_alive() {
  kill -0 "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_status() {
  echo "=== Shared deps ==="
  if nc -z -w 2 localhost 5432 >/dev/null 2>&1; then
    echo "  postgres:5432  reachable"
  else
    echo "  postgres:5432  UNREACHABLE"
  fi
  if nc -z -w 2 localhost 6379 >/dev/null 2>&1; then
    echo "  redis:6379     reachable"
  else
    echo "  redis:6379     UNREACHABLE"
  fi

  echo ""
  echo "=== Port-forwards ==="
  if [ ! -f "$PF_PIDS_FILE" ]; then
    echo "  (none tracked)"
    return 0
  fi

  while IFS=: read -r name pid; do
    [ -z "$name" ] && continue
    if pf_alive "$pid"; then
      echo "  ${name}: running (pid ${pid})"
    else
      echo "  ${name}: DEAD (pid ${pid} — stale entry)"
    fi
  done < "$PF_PIDS_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SUBCOMMAND="${1:-}"

case "$SUBCOMMAND" in
  status) cmd_status ;;
  *)
    echo "Usage: bin/deps <start|stop|status>" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x bin/deps
```

- [ ] **Step 3: Verify `status` works**

```bash
bin/deps status
```

Expected output (if postgres/redis are up):
```
=== Shared deps ===
  postgres:5432  reachable
  redis:6379     reachable

=== Port-forwards ===
  (none tracked)
```

If deps are down both lines will show `UNREACHABLE` — that's fine at this stage.

- [ ] **Step 4: Verify unknown subcommand exits non-zero**

```bash
bin/deps unknown; echo "exit: $?"
```

Expected:
```
Usage: bin/deps <start|stop|status>
exit: 1
```

- [ ] **Step 5: Commit**

```bash
git checkout -b feature/deps-daemon
git add bin/deps
git commit -m "feat(dev): add bin/deps skeleton with status subcommand"
```

---

## Task 2: Add `start` subcommand (k8s deps only)

**Files:**
- Modify: `bin/deps`

- [ ] **Step 1: Add `start_k8s_deps`, `wait_for_deps`, and `cmd_start` to `bin/deps`**

Add these functions after the `pf_alive` helper (before the `cmd_status` function):

```bash
start_k8s_deps() {
  echo "Starting shared deps (skaffold run -f ${DEPS_SKAFFOLD})..."
  local cmd=(skaffold run -f "$DEPS_SKAFFOLD")
  [ -n "$K8S_CONTEXT" ] && cmd+=(--kube-context "$K8S_CONTEXT")
  "${cmd[@]}"
}

wait_for_deps() {
  local waited=0
  until deps_reachable; do
    if [ "$waited" -ge "$DEPS_WAIT_SECONDS" ]; then
      echo "ERROR: shared deps did not become reachable within ${DEPS_WAIT_SECONDS}s." >&2
      echo "       Check: kubectl get pods -n default" >&2
      exit 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
}

cmd_start() {
  if deps_reachable; then
    echo "Shared deps already up (postgres:5432, redis:6379)."
  else
    if mkdir "$DEPS_LOCK" 2>/dev/null; then
      # shellcheck disable=SC2064
      trap "rmdir '$DEPS_LOCK' 2>/dev/null || true" EXIT
      deps_reachable || start_k8s_deps
      rmdir "$DEPS_LOCK" 2>/dev/null || true
      trap - EXIT
    else
      echo "Another worktree is starting shared deps; waiting..."
    fi
    wait_for_deps
    echo "Shared deps are up."
  fi
}
```

Then add `start` to the `case` statement in Main:

```bash
case "$SUBCOMMAND" in
  start)  cmd_start ;;
  status) cmd_status ;;
  *)
    echo "Usage: bin/deps <start|stop|status>" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 2: Verify `start` is idempotent when deps are already up**

With the k8s stack running:

```bash
bin/deps start
```

Expected:
```
Shared deps already up (postgres:5432, redis:6379).
```

Exit code must be 0:
```bash
bin/deps start; echo "exit: $?"
```
Expected: `exit: 0`

- [ ] **Step 3: Commit**

```bash
git add bin/deps
git commit -m "feat(dev): add start subcommand to bin/deps"
```

---

## Task 3: Add OTLP port-forward to `start` and add `stop` subcommand

**Files:**
- Modify: `bin/deps`

- [ ] **Step 1: Add `start_port_forward` helper and wire it into `cmd_start`**

Add `start_port_forward` after `pf_alive`:

```bash
start_port_forward() {
  local name="$1" svc="$2" port="$3"

  if port_reachable "$port"; then
    echo "  ${name}: already reachable on :${port}"
    return 0
  fi

  local existing_pid
  existing_pid="$(pf_pid_for "$name")" || true
  if [ -n "$existing_pid" ] && pf_alive "$existing_pid"; then
    echo "  ${name}: port-forward already running (pid ${existing_pid})"
    return 0
  fi

  echo "  ${name}: starting kubectl port-forward ${svc} ${port}:${port}..."
  kubectl port-forward "$svc" "${port}:${port}" >/dev/null 2>&1 &
  local pid=$!
  pf_write_pid "$name" "$pid"
  echo "  ${name}: started (pid ${pid})"
}
```

Append to the end of `cmd_start` (inside the function, after the k8s-deps block):

```bash
  # Start port-forwards when tracing is enabled
  if [ "$OTEL_ENABLED" = "true" ]; then
    echo "OTEL_ENABLED=true — ensuring OTLP port-forward..."
    start_port_forward "otlp" "svc/jaeger-collector" "4318"
  fi
```

- [ ] **Step 2: Add `cmd_stop` function**

Add after `cmd_start`:

```bash
cmd_stop() {
  if [ ! -f "$PF_PIDS_FILE" ]; then
    echo "No port-forwards tracked (${PF_PIDS_FILE} not found)."
    return 0
  fi

  while IFS=: read -r name pid; do
    [ -z "$name" ] && continue
    if pf_alive "$pid"; then
      echo "Stopping ${name} (pid ${pid})..."
      kill "$pid" 2>/dev/null || true
    else
      echo "  ${name} (pid ${pid}): already stopped (stale entry)"
    fi
  done < "$PF_PIDS_FILE"

  rm -f "$PF_PIDS_FILE"
  echo "Done."
}
```

Add `stop` to the `case` statement:

```bash
case "$SUBCOMMAND" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *)
    echo "Usage: bin/deps <start|stop|status>" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 3: Verify port-forward starts when OTEL_ENABLED=true**

With the k8s stack running (Jaeger deployed):

```bash
OTEL_ENABLED=true bin/deps start
```

Expected output includes:
```
Shared deps already up (postgres:5432, redis:6379).
OTEL_ENABLED=true — ensuring OTLP port-forward...
  otlp: starting kubectl port-forward svc/jaeger-collector 4318:4318...
  otlp: started (pid <some-pid>)
```

- [ ] **Step 4: Verify status shows the running port-forward**

```bash
bin/deps status
```

Expected:
```
=== Shared deps ===
  postgres:5432  reachable
  redis:6379     reachable

=== Port-forwards ===
  otlp: running (pid <some-pid>)
```

- [ ] **Step 5: Verify `start` is idempotent (second call skips)**

```bash
OTEL_ENABLED=true bin/deps start
```

Expected (no new process spawned):
```
Shared deps already up (postgres:5432, redis:6379).
OTEL_ENABLED=true — ensuring OTLP port-forward...
  otlp: already reachable on :4318
```

- [ ] **Step 6: Verify `stop` kills the port-forward**

```bash
bin/deps stop
bin/deps status
```

Expected after stop:
```
Stopping otlp (pid <some-pid>)...
Done.
```

Expected status after stop:
```
=== Port-forwards ===
  (none tracked)
```

- [ ] **Step 7: Verify `stop` handles missing PID file gracefully**

```bash
bin/deps stop
```

Expected (no PID file present):
```
No port-forwards tracked (/path/to/.git/rails-llm-pf.pids not found).
```

Exit code 0:
```bash
bin/deps stop; echo "exit: $?"
# exit: 0
```

- [ ] **Step 8: Commit**

```bash
git add bin/deps
git commit -m "feat(dev): add OTLP port-forward management and stop subcommand to bin/deps"
```

---

## Task 4: Simplify `bin/dev`

**Files:**
- Modify: `bin/dev`

- [ ] **Step 1: Replace the dep management block in `bin/dev`**

The current `bin/dev` has these variables and functions that move to `bin/deps` and must be removed:

```
DEPS_SKAFFOLD="skaffold.deps.yaml"
GIT_COMMON_DIR=...
DEPS_LOCK=...
DEPS_WAIT_SECONDS=240
deps_reachable()
wait_for_deps()
start_deps()
ensure_deps()
ensure_deps   <-- the call
```

Replace the entire file with:

```bash
#!/usr/bin/env bash
set -euo pipefail

# bin/dev — start this worktree's Rails server for parallel local development.
#
# One command, non-interactive. It:
#   1. Resolves this worktree's slot (stable per-worktree port + database names).
#   2. Ensures the SHARED dependency stack is up via bin/deps start.
#   3. Creates/migrates this worktree's databases (idempotent db:prepare).
#   4. Runs Rails locally on this worktree's port against the shared deps.
#
# Multiple worktrees can run bin/dev concurrently: they share one set of
# dependencies and differ only in their Rails port and database names.
#
# To manage deps independently: bin/deps start|stop|status

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Load .env (DB creds, LLM endpoint, OTEL settings). Optional.
# ---------------------------------------------------------------------------

if [ -f .env ]; then
  set -o allexport
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    export "$line" 2>/dev/null || true
  done < .env
  set +o allexport
fi

# ---------------------------------------------------------------------------
# Resolve this worktree's slot config (SLOT, RAILS_PORT, *_DATABASE_URL).
# bin/use-slot assigns a slot on first run and is idempotent thereafter.
# ---------------------------------------------------------------------------

eval "$(ruby bin/use-slot --env)"

SLOT="${SLOT:-1}"
RAILS_PORT="${RAILS_PORT:-3000}"

# ---------------------------------------------------------------------------
# Shared dependency stack (delegates to bin/deps)
# ---------------------------------------------------------------------------

bin/deps start

# ---------------------------------------------------------------------------
# Per-worktree databases (idempotent: creates + migrates if missing).
# ---------------------------------------------------------------------------

echo "Preparing databases for slot ${SLOT}..."
bin/rails db:prepare

# ---------------------------------------------------------------------------
# Run Rails
# ---------------------------------------------------------------------------

echo ""
echo "Slot ${SLOT}: Rails on http://localhost:${RAILS_PORT}"
echo ""
exec bin/rails server -p "$RAILS_PORT" -b 0.0.0.0
```

- [ ] **Step 2: Verify `bin/dev` still starts Rails correctly**

With deps already running:

```bash
bin/dev
```

Expected to see (before Rails starts):
```
Shared deps already up (postgres:5432, redis:6379).
Preparing databases for slot 1...
...
Slot 1: Rails on http://localhost:3000
```

Rails should start normally. Ctrl-C to stop.

- [ ] **Step 3: Verify OTEL port-forward starts automatically when enabled**

With `OTEL_ENABLED=true` in `.env`:

```bash
bin/dev
```

Expected output to include:
```
Shared deps already up (postgres:5432, redis:6379).
OTEL_ENABLED=true — ensuring OTLP port-forward...
  otlp: starting kubectl port-forward svc/jaeger-collector 4318:4318...
  otlp: started (pid <some-pid>)
Preparing databases for slot 1...
```

- [ ] **Step 4: Commit**

```bash
git add bin/dev
git commit -m "refactor(dev): delegate dep lifecycle to bin/deps"
```

---

## Task 5: Update `.env.example`

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Remove the TODO comment and update the OTEL section**

Find this block in `.env.example`:

```
# --- Observability — set OTEL_ENABLED=true to activate tracing. ---
OTEL_ENABLED=false
# When Rails runs locally, this must point at a localhost-reachable OTLP endpoint.
# NOTE: exposing the shared jaeger-collector on localhost:4318 is a follow-up;
# until then leave OTEL_ENABLED=false or port-forward jaeger-collector manually.
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_SERVICE_NAME=rails-llm-demo
```

Replace with:

```
# --- Observability — set OTEL_ENABLED=true to activate tracing. ---
OTEL_ENABLED=false
# When OTEL_ENABLED=true, bin/deps automatically port-forwards jaeger-collector
# to localhost:4318 so traces flow to Jaeger without any manual kubectl commands.
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_SERVICE_NAME=rails-llm-demo
```

- [ ] **Step 2: Verify the file looks correct**

```bash
grep -A5 "OTEL_ENABLED" .env.example
```

Expected:
```
OTEL_ENABLED=false
# When OTEL_ENABLED=true, bin/deps automatically port-forwards jaeger-collector
# to localhost:4318 so traces flow to Jaeger without any manual kubectl commands.
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_SERVICE_NAME=rails-llm-demo
```

- [ ] **Step 3: Commit**

```bash
git add .env.example
git commit -m "docs(dev): remove OTLP port-forward TODO from .env.example"
```

---

## Task 6: Final integration test and push

- [ ] **Step 1: Run the full CI suite**

```bash
bin/ci
```

Expected: all checks pass (bin/deps is a bash script; no Ruby tests affected).

- [ ] **Step 2: Verify the complete workflow end-to-end**

```bash
# Stop any existing port-forwards
bin/deps stop

# Confirm nothing tracked
bin/deps status

# Start everything fresh with OTEL enabled
OTEL_ENABLED=true bin/deps start

# Confirm status
bin/deps status

# Start Rails and verify it works
bin/dev &
DEV_PID=$!
sleep 5
curl -s http://localhost:3000 | grep -q "Chats" && echo "Rails OK" || echo "Rails FAILED"
kill $DEV_PID 2>/dev/null || true

# Stop port-forwards
bin/deps stop
bin/deps status
```

Expected:
- `bin/deps status` after start shows postgres, redis reachable and `otlp: running`
- Rails responds at localhost:3000
- `bin/deps status` after stop shows `(none tracked)`

- [ ] **Step 3: Push branch and open PR**

```bash
git push -u origin feature/deps-daemon
gh pr create \
  --title "feat(dev): bin/deps daemon for shared dep + port-forward lifecycle" \
  --body "$(cat <<'EOF'
## Summary
- Extracts dep management from \`bin/dev\` into a new \`bin/deps start|stop|status\` script
- \`bin/deps start\` auto-spawns OTLP port-forward (jaeger-collector:4318) when \`OTEL_ENABLED=true\`
- \`bin/dev\` becomes Rails-only, calling \`bin/deps start\` automatically if deps aren't up
- Removes the TODO comment in \`.env.example\` — \`OTEL_ENABLED=true\` now just works

## Test plan
- [ ] \`bin/deps status\` shows dep reachability and tracked PIDs
- [ ] \`bin/deps start\` is idempotent; skips if already up
- [ ] \`OTEL_ENABLED=true bin/deps start\` spawns jaeger-collector port-forward
- [ ] \`bin/deps stop\` kills port-forwards and removes PID file
- [ ] \`bin/dev\` still starts Rails correctly with no dep logic visible
- [ ] CI passes

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

