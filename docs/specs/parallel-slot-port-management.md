# Design: Parallel Slot Port Management

**Status:** Draft — pending architecture review  
**Date:** 2026-05-30  
**Supersedes:** `future-multi-instance-ports.md`

---

## Problem

Every port in the stack is hardcoded in `skaffold.yaml` and `.env.example`. A developer running a second instance of this app — via a git worktree, a second clone, or a parallel branch — will hit silent port-forward conflicts with no clean override path.

Current hardcoded ports:

| Port  | Service            | Defined in                          |
|-------|--------------------|-------------------------------------|
| 3000  | Rails app          | `skaffold.yaml` portForward         |
| 3001  | Grafana            | `skaffold.yaml` portForward         |
| 3100  | Loki               | `skaffold.yaml` portForward         |
| 4318  | Jaeger OTLP        | `skaffold.yaml` portForward + `.env`|
| 5432  | Postgres           | `skaffold.yaml` portForward + `.env`|
| 6379  | Redis              | `skaffold.yaml` portForward + `.env`|
| 9090  | Prometheus         | `skaffold.yaml` portForward         |
| 16686 | Jaeger UI          | `skaffold.yaml` portForward         |

---

## Goals

- A developer can run two or more instances of the stack concurrently without manual port editing.
- `.env` is the single source of truth for port configuration per worktree instance.
- Port assignments are explicit and human-readable — no runtime math hidden inside scripts.
- Port conflicts with other processes on the machine are detected before startup, not discovered at crash time.
- The solution works naturally with git worktrees (each worktree has its own `.env`).

## Non-goals

- Dynamic port assignment at runtime (ports must be stable for the lifetime of a session).
- Supporting more than ~5 concurrent slots (2–3 is the realistic ceiling for a laptop).
- Changing production or Kamal deployment configuration.

---

## Design

### Slot concept

A **slot** is a named port allocation for one instance of the stack. Slot 1 is the default (base ports, no changes needed for an existing setup). Slots 2, 3, etc. are parallel instances.

Each worktree declares its slot via a single variable in `.env`:

```
SLOT=2
```

All other port variables are stored explicitly alongside it:

```
SLOT=2
RAILS_PORT=3020
GRAFANA_PORT=3021
LOKI_PORT=3120
OTEL_PORT=4338
DB_PORT=5452
REDIS_PORT=6399
PROMETHEUS_PORT=9110
JAEGER_PORT=16706
```

The slot number is metadata — it documents intent. The port values are authoritative.

### Port generation heuristic

`bin/use-slot N` uses a +20 offset per slot as a starting heuristic to generate candidate ports:

```
candidate_port = base_port + (N - 1) * 20
```

+20 was chosen because the stack has 8 services, so a 20-port window leaves 12 unused ports between slots as buffer against accidental overlap with neighbouring applications.

The heuristic produces **candidates only**. The script then validates each candidate.

### Port availability check

Before writing any port to `.env`, `bin/use-slot` checks whether the candidate is already bound on the local machine:

```bash
lsof -i :CANDIDATE_PORT -sTCP:LISTEN -t
```

If the port is free, it is used. If taken, the script increments by 1 and retries until it finds a free port, up to a configurable limit (default: 10 attempts per service). If no free port is found within the window, the script exits with an error and reports which service could not be allocated.

This means the resolved ports may not be perfectly offset-aligned — that is intentional. The stored values are correct; the offset is just a starting point.

### .env as source of truth

After resolving all ports, `bin/use-slot` writes the full explicit mapping to the worktree's `.env`. No downstream tool performs any port arithmetic — they read the value directly.

Rails reads `DB_PORT`, `REDIS_PORT`, `OTEL_EXPORTER_OTLP_ENDPOINT` (constructed from `OTEL_PORT`) from `.env` via the existing dotenv setup.

Skaffold reads port values via a generated profile (see below).

### Skaffold profile generation

Skaffold's `portForward.localPort` does not support environment variable interpolation. To bridge this, `bin/use-slot` generates a Skaffold profile file at:

```
.skaffold/slot-N.yaml
```

This is a partial Skaffold config using the `profiles` key that overrides `portForward` with the resolved port values. It is gitignored (generated, instance-specific). The developer activates it with:

```bash
skaffold dev --profile slot-2
```

Or via `bin/dev` which reads `SLOT` from `.env` and passes the correct profile flag automatically.

### bin/use-slot script behaviour

```
bin/use-slot [SLOT_NUMBER]
```

1. Reads base ports from a hardcoded table in the script.
2. Computes candidate ports using the offset formula.
3. Checks each candidate port for availability; nudges if taken.
4. Writes resolved ports to `.env` (prompts for confirmation if `.env` already exists with a different `SLOT`).
5. Generates `.skaffold/slot-N.yaml` with the resolved port values.
6. Prints a summary of assigned ports and the command to start the stack.

Slot 1 is the default — running `bin/use-slot 1` writes the base ports and generates no profile override (slot 1 uses `skaffold.yaml` as-is).

### bin/dev wrapper

`bin/dev` replaces the two-terminal workflow. It:

1. Reads `SLOT` from `.env`.
2. Constructs the correct `skaffold dev` invocation (with `--profile slot-N` for N > 1).
3. Starts Rails server with `bin/rails server -p $RAILS_PORT`.
4. Manages both processes with a simple `Procfile` via `foreman`, or a trap-based shell approach if foreman is unavailable.

### .gitignore additions

```
.env
.skaffold/
```

`.env.example` remains committed and contains `SLOT=1` with base port values as defaults.

---

## File changes summary

| File | Change |
|------|--------|
| `bin/use-slot` | New script — port resolution + .env + profile generation |
| `bin/dev` | New script — reads SLOT, starts skaffold + rails |
| `.env.example` | Add `SLOT=1` and all explicit port variables |
| `.skaffold/slot-N.yaml` | Generated per instance, gitignored |
| `.gitignore` | Add `.skaffold/` |
| `docs/decisions.md` | Document slot convention and workflow |
| `docs/specs/future-multi-instance-ports.md` | Mark superseded |

`skaffold.yaml` itself is **not modified** — slot 1 continues to work as-is. Only generated slot profiles introduce port overrides.

---

## Open questions for architecture review

1. **Skaffold profile merge strategy** — does a partial profile YAML in `.skaffold/slot-N.yaml` correctly override only `portForward` without duplicating the full release list? Need to verify Skaffold's config merge behaviour for externally referenced profiles.

2. **Kubernetes namespace isolation** — should each slot deploy into its own namespace (e.g., `default`, `rails-llm-slot2`) to prevent pod name collisions if two slots run against the same cluster? Or is port separation sufficient?

3. **`bin/dev` process management** — `foreman` is not in the Gemfile. Should it be added, or should `bin/dev` use a trap-based shell approach to keep dependencies minimal?

4. **lsof availability** — `lsof` is standard on macOS but not guaranteed on Linux. Should the availability check fall back to `ss -ltn` or `netstat` on non-macOS platforms?

5. **Port variable naming** — `OTEL_EXPORTER_OTLP_ENDPOINT` is a URL, not a bare port. Should `bin/use-slot` write both `OTEL_PORT=4338` (the resolved port) and construct the full URL, or leave URL construction to the app?

---

## Architecture Validation

**Date:** 2026-06-02 · **Verdict:** Approach viable, implemented with the deviations noted below.

The open questions above were resolved experimentally (a hand-authored `slot-2-test.yaml`
plus `skaffold diagnose`) and through the implementation. The composition mechanic was
switched from a partial **profile** override to full-file **`requires` composition**, which
is what `bin/use-slot` now generates.

| Question | Resolution |
|----------|------------|
| 1. Merge strategy | **`requires` composition works.** A slot file with `requires: [{path: skaffold.yaml}]` and no `build` block inherits the parent's build artifacts — `skaffold diagnose` reports the slot config as 0 artifacts composed with the parent's 1 (`rails-app`). No duplicate build stanza needed. The earlier "partial profile override" idea was dropped in favour of a self-contained slot file that redeclares `portForward` and `deploy.helm.releases` (each pinned to namespace `slot-N`). |
| 2. Namespace isolation | **Each slot gets its own namespace** (`slot-N`, `createNamespace: true` on every release). Port separation alone is insufficient — pods and Helm releases would otherwise collide. Helm treats `postgres` in `default` and `postgres` in `slot-2` as distinct releases. |
| 3. `bin/dev` process management | **Trap-based bash, no foreman.** `bin/dev` backgrounds `skaffold dev` and traps `EXIT/INT/TERM` to kill it, then `exec`s the Rails server in the foreground. No new dependency added. |
| 4. `lsof` availability | **Three-tier check** in `bin/use-slot`: `lsof` → `ss` → Ruby `TCPServer` bind. Works on macOS and Linux without `lsof`. |
| 5. Port variable naming | `bin/use-slot` writes the bare `OTEL_PORT` **and** constructs the full `OTEL_EXPORTER_OTLP_ENDPOINT` / `REDIS_URL` URLs into `.env`. |

### Critical finding — `requires.path` is resolved relative to the working directory

Skaffold resolves `requires.path` (and the relative `chartPath:` / `valuesFiles:` entries)
against the **current working directory**, *not* against the slot file's own location.
A `path: ../skaffold.yaml` therefore pointed one level *above* the repo and failed with
"could not find skaffold config file". Verified by running `skaffold diagnose` from both
the repo root and `charts/`: the lookup base tracked the cwd in every case, independent of
`--filename`.

Consequences, both implemented:
- `bin/use-slot` generates `requires: [{path: skaffold.yaml}]` (repo-root-relative).
- `bin/dev` `cd`s to the repo root before invoking skaffold so the cwd is deterministic.

### Postgres hostPath override

The chart key is `storage.hostPath` (not `persistence.hostPath` as the plan speculated).
`helm template charts/postgres --set storage.hostPath=…` overrides it cleanly; the default
(`/tmp/rails-llm-demo/postgres`) is unchanged, so slot 1 is unaffected. The generated slot
file sets `storage.hostPath: /tmp/rails-llm-demo/postgres-slot-N` on the postgres release only.
