# Design: `bin/deps` Background Daemon + `bin/dev` Simplification

**Date:** 2026-06-06
**Branch:** feature/deps-daemon
**Status:** Approved, pending implementation

---

## Problem

`bin/dev` currently bundles dependency management (starting the k8s stack, waiting for
readiness, locking against concurrent worktrees) with application startup (slot resolution,
DB preparation, Rails). This makes it impossible to:

- Restart Rails without touching deps.
- Manage port-forwards (e.g. OTLP collector) as first-class lifecycle objects.
- Start/stop deps independently for debugging or orchestration.

The OTLP port-forward for Jaeger (needed when `OTEL_ENABLED=true` with a local Rails
server) has no managed home — the `.env.example` has a TODO comment acknowledging this gap.

---

## Solution

Extract dep management into a new `bin/deps start|stop|status` script that runs as a
background daemon. `bin/dev` becomes Rails-only, calling `bin/deps start` automatically
if deps are not yet up.

---

## Architecture

### `bin/deps` — new script

Three subcommands:

| Command | Behaviour |
|---|---|
| `bin/deps start` | Ensures k8s deps are up (skaffold run, idempotent). If `OTEL_ENABLED=true`, spawns `kubectl port-forward svc/jaeger-collector 4318:4318` in the background and records its PID. Safe to call when already running. |
| `bin/deps stop` | Reads the PID file, kills tracked port-forward processes, removes the PID file. Does **not** tear down the k8s stack — Skaffold-managed resources stay up. |
| `bin/deps status` | Reports postgres:5432 and redis:6379 reachability, and liveness of each tracked port-forward process. |

### PID file

- **Location:** `$GIT_COMMON_DIR/rails-llm-pf.pids`
- Same directory pattern as the slot registry — shared across worktrees, never committed.
- **Format:** one `name:PID` entry per line, e.g.:

  ```
  otlp:12345
  ```

- Designed for future extension (e.g. `jaeger-ui:67890` when the Jaeger UI forward is added).

### `bin/dev` — simplified

The inline `ensure_deps` block (~40 lines) is replaced by a single call to `bin/deps start`.
Everything else is unchanged:

| Step | After |
|---|---|
| Load `.env` | unchanged |
| Resolve slot (bin/use-slot) | unchanged |
| Call `bin/deps start` | replaces inline ensure_deps block |
| Prepare databases (db:prepare) | unchanged |
| Start Rails (`exec bin/rails server`) | unchanged |

`exec` is preserved — Rails remains the process that receives signals. Port-forward
lifecycle is entirely `bin/deps`'s responsibility.

### `.env.example`

Remove the TODO comment about OTLP port-forwarding being a follow-up. With this change,
`OTEL_ENABLED=true` works out of the box.

---

## Error Handling & Edge Cases

**Port 4318 already reachable:** `bin/deps start` checks `nc -z -w 1 localhost 4318`
before spawning. If already reachable, it skips and logs "OTLP already reachable on :4318".
Handles existing manual port-forwards or local Jaeger instances.

**Stale PID file:** On start, each recorded PID is checked with `kill -0 <pid>`. Dead
entries are cleaned up and re-spawned. `bin/deps stop` handles stale PIDs gracefully —
warns but does not fail.

**Multiple worktrees with OTEL_ENABLED=true:** The port-forward binds `localhost:4318` at
the OS level — only one process can own it. The second worktree's `bin/deps start` sees
port 4318 already reachable and skips spawning. Both worktrees share the same Jaeger
collector — correct behaviour.

**k8s not running / skaffold fails:** Behaviour unchanged — `bin/deps start` exits
non-zero and `bin/dev` inherits the failure.

---

## Files Changed

| File | Change |
|---|---|
| `bin/deps` | **New.** start/stop/status subcommands with PID file management. |
| `bin/dev` | **Modified.** Remove inline `ensure_deps` block; call `bin/deps start` instead. |
| `.env.example` | **Modified.** Remove TODO comment on OTLP port-forward. |

---

## Out of Scope

- Jaeger UI port-forward (16686) — not added here; PID file format supports it as a
  future extension.
- Tearing down the k8s stack via `bin/deps stop` — use `skaffold delete` directly.
- Any changes to `skaffold.deps.yaml` or Helm charts.
