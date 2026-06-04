# Plan: Parallel Worktrees via Shared Deps + Per-Worktree Local Rails

**Status:** Implemented + live-validated (pending commit / real-worktree run)
**Date:** 2026-06-04
**Branch:** `feature/parallel-slot-port-management`
**Supersedes:** the per-slot-full-stack design in PR #28 (`docs/specs/parallel-slot-port-management.md`)

---

## Goal

Make it trivial — for both a human and an AI agent — to run multiple git worktrees
of this project concurrently on one laptop. A single non-interactive command per
worktree should "just work": start or reuse shared dependencies, pick a stable
port, isolate the database, and launch Rails.

## Decisions (locked via Q&A 2026-06-04)

1. **Sharing model:** one shared dependency stack (postgres + redis + observability),
   reused across worktrees. Each worktree runs **only its own Rails app** on its own
   port, pointed at the shared deps.
2. **DB isolation:** same postgres cluster, **separate logical databases per worktree**
   (slot-suffixed). Created on start (idempotent `db:prepare`).
3. **Slot derivation:** a **gitignored registry file** maps worktree path → slot,
   first-come assignment. Stable and human-readable.
4. **Primary user:** both a human dev and a non-interactive AI agent. No TTY prompts.
5. **Rails topology:** Rails runs **locally** (`bin/rails server -p <port>`) against the
   shared, localhost-reachable deps. Matches today's documented dev loop.
6. **PR #28 disposition:** **rework this branch** to the shared-deps design.
7. **Deps lifecycle/reachability:** expose shared deps via **LoadBalancer/NodePort** on
   docker-desktop so they bind to `localhost` with no `kubectl port-forward` process to
   babysit. Fire-and-forget.

---

## Architecture

### Shared deps (started once)

- Namespace: `default`.
- Releases: `postgres`, `redis`, `kube-prometheus-stack`, `loki`, `jaeger`, `fluent-bit`.
  **No `rails-app`** — Rails runs locally per worktree.
- Service types: **LoadBalancer** (docker-desktop → `localhost`), falling back to
  NodePort for any service that won't bind cleanly.
- Fixed localhost ports (shared by all worktrees):

  | Service     | Port  |
  |-------------|-------|
  | postgres    | 5432  |
  | redis       | 6379  |
  | grafana     | 3001  |
  | prometheus  | 9090  |
  | loki        | 3100  |
  | jaeger UI   | 16686 |
  | OTLP (jaeger-collector) | 4318 |

- Deployed via a new **`skaffold.deps.yaml`** (deps-only). The original `skaffold.yaml`
  (full in-cluster deploy incl. rails-app) is left untouched for the in-cluster path.

### Per-worktree Rails

- Only the **Rails port** varies per worktree: slot 1 → `3000`, slot 2 → `3010`,
  slot 3 → `3020`, … (offset 10, avoids the fixed `3001`/`3100`). Availability-checked
  and nudged if taken.
- **Database isolation** via slot-suffixed DB names, injected as connection URLs so
  `config/database.yml` is unchanged:
  - Slot 1 (backward compatible): `chatbot_development`, `_queue`, `_cable`, `_cache`.
  - Slot N: `chatbot_development_sN`, `_sN_queue`, `_sN_cable`, `_sN_cache`.
  - Env: `DATABASE_URL`, `QUEUE_DATABASE_URL`, `CABLE_DATABASE_URL`, `CACHE_DATABASE_URL`
    (host `localhost`, port `5432`).

### Slot registry

- File: `.git/rails-llm-slots.json` — lives in the shared `git rev-parse --git-common-dir`,
  so every worktree sees the same registry; inside `.git` so never committed.
- Shape: `{ "<worktree-abspath>": <slot:int>, ... }`.
- First-come assignment: a new worktree gets the lowest free slot.

---

## The one command — `bin/dev`

Non-interactive. Steps:

1. Resolve this worktree's slot from the registry (assign next free if new)
   → `RAILS_PORT` + slot-suffixed DB names.
2. Check whether shared deps are Ready in `default`. If not, `skaffold run -f skaffold.deps.yaml`
   (guarded by a lockfile in the git-common-dir so concurrent first-starts don't race).
3. Wait until deps are Ready and the `localhost` deps ports answer.
4. `bin/rails db:prepare` (idempotent — creates this worktree's databases if missing).
5. `exec bin/rails server -p $RAILS_PORT -b 0.0.0.0`.

Supporting command `bin/use-slot` (reworked): no-arg resolves/assigns and prints a
summary; `--print` emits just the slot number for scripting; `--release` frees the
current worktree's slot.

---

## Files

**New**
- `skaffold.deps.yaml` — deps-only stack, LoadBalancer service types.
- `test/lib/slot_registry_test.rb` (or similar) — unit tests for the resolver.

**Rewrite**
- `bin/dev` — orchestrator (above).
- `bin/use-slot` — registry-backed resolver (replaces port-offset-everything logic).
- `bin/setup-worktree` — simplified (register + optional start).
- `docs/decisions.md` — replace the slot section with the shared-deps decision.
- `docs/specs/parallel-slot-port-management.md` — mark superseded by this doc.
- `.env.example` — slim: fixed deps ports + app config + slot.

**Delete**
- Per-slot `.skaffold/slot-N.yaml` generation, per-slot namespaces, 8-service port-offset.

**Tweak**
- `charts/postgres/values.yaml`, `charts/redis/values.yaml` — service type (or via skaffold
  `setValues`). Remote-chart service types via skaffold value overrides.
- `.gitignore` — drop `.skaffold/` if no longer generated.

`config/database.yml` — unchanged (URL injection).

---

## Validation

- **Early risk:** LoadBalancer-on-localhost for postgres/redis (raw TCP) on docker-desktop.
  Prove with the postgres service first; fall back to NodePort per-service if needed.
- **Unit:** slot resolver — assign / idempotent-reuse / next-free / release.
- **Manual smoke:** two worktrees, two Rails on different ports, shared postgres, separate
  databases, both able to chat.

---

## Validation results (2026-06-04)

Live end-to-end test on docker-desktop — **passed**:

- LoadBalancer-on-localhost confirmed for raw TCP (postgres `5432`, redis `6379`) and
  HTTP (grafana `3001`, prometheus `9090`). `skaffold run -f skaffold.deps.yaml` completed
  exit 0; the deps services bound to `localhost` with no port-forward process.
- `bin/dev` brought up slot 1: resolved the slot, ran `db:prepare` (created
  `chatbot_development` + `_queue`/`_cable`/`_cache`), started Rails + SolidQueue on
  `:3000` → HTTP 200.
- A second instance (slot 2) ran concurrently on `:3010` against the same shared
  postgres/redis but its own `chatbot_development_s2*` databases → HTTP 200.
- **Isolation proven:** a `Chat` created via slot 1 appeared only in `chatbot_development`
  (count 1) and not in `chatbot_development_s2` (count 0).
- Unit suite green (16 tests), rubocop clean, brakeman 0 warnings.

Notes:
- The shared `auth.password` is `password` (chart) — auth confirmed over TCP. `.env.example`
  was corrected to match.
- **docker-desktop hostPath cache (important):** the postgres data lives on a hostPath
  inside the cluster VM, and docker-desktop's VirtioFS cache *resurrects deleted contents*
  when a new pod mounts the path. Deleting `pgdata` — from the host OR an in-cluster Job —
  does NOT give postgres a clean slate; it scales back up with the old cluster (verified:
  a fresh pod saw the dir gone, yet postgres re-materialized it on start). `bin/reset-db`
  was therefore rewritten to reset via SQL (drop + recreate the databases through the
  running postgres), which is reliable and properly scoped to this worktree's slot DBs.
- Real second-worktree run (vs. the same-dir slot-2 simulation) is pending a commit, since
  a new worktree checks out HEAD.

## Out of scope

- Production / Kamal deployment (unchanged).
- The in-cluster full deploy path (`skaffold.yaml`, `feature/fix-incluster-deploy`).
- More than ~5 concurrent worktrees.
