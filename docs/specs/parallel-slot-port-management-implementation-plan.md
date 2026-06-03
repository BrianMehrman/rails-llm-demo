# Implementation Plan: Parallel Slot Port Management

**Status:** Ready for implementation  
**Date:** 2026-05-30  
**Input documents:** `docs/specs/parallel-slot-port-management.md`, architecture review findings  
**Supersedes:** `docs/specs/future-multi-instance-ports.md`

---

## Scope

Enable two or more git worktrees of `rails-llm-demo` to run their full Skaffold + Kubernetes stacks concurrently on one laptop without port conflicts.

The mechanism is a `bin/use-slot N` script that resolves ports, writes them explicitly to `.env`, and generates a `.skaffold/slot-N.yaml` file using Skaffold's `requires` composition. A revised `bin/dev` reads `SLOT` from `.env` and hands off to the correct Skaffold file. Slot 1 is the default and requires no changes to an existing setup.

**Out of scope:** production/Kamal config, dynamic port assignment at runtime, more than ~5 concurrent slots.

---

## Sequencing rationale

Phase 1 validates the Skaffold `requires` composition mechanic before writing any tooling against it — this is the highest technical risk and must be proven experimentally first. Phase 2 lays the static foundation (`.env.example`, `.gitignore`, Postgres chart). Phase 3 builds `bin/use-slot`. Phase 4 wires `bin/dev` and `bin/setup-worktree`. Phase 5 documents and closes.

---

## Phase 1 — Validate Skaffold `requires` composition

**Rationale:** The architecture review identified Skaffold profile composition via `requires` as an experimental unknown. Nothing else can be built confidently until this is proven to work as described. This phase produces no committed code — only a documented finding that unlocks the rest of the plan.

### Task 1.1 — Manually author a slot-2 override file and test it

Create `.skaffold/slot-2-test.yaml` by hand with the following skeleton:

```yaml
apiVersion: skaffold/v4beta11
kind: Config
requires:
  - path: ../skaffold.yaml

portForward:
  - resourceType: service
    resourceName: postgres
    namespace: slot-2
    port: 5432
    localPort: 5452
  - resourceType: service
    resourceName: redis
    namespace: slot-2
    port: 6379
    localPort: 6399
  - resourceType: service
    resourceName: rails-app
    namespace: slot-2
    port: 3000
    localPort: 3020

deploy:
  helm:
    releases:
      - name: postgres
        chartPath: charts/postgres
        valuesFiles:
          - charts/postgres/values.yaml
        namespace: slot-2
        createNamespace: true
        setValues:
          persistence.hostPath: /tmp/rails-llm-demo/postgres-slot-2
      - name: redis
        chartPath: charts/redis
        valuesFiles:
          - charts/redis/values.yaml
        namespace: slot-2
        createNamespace: true
      - name: kube-prometheus-stack
        remoteChart: kube-prometheus-stack
        repo: https://prometheus-community.github.io/helm-charts
        version: "65.1.1"
        valuesFiles:
          - charts/kube-prometheus-stack/values.yaml
        namespace: slot-2
        createNamespace: true
      - name: rails-app
        chartPath: charts/rails-app
        valuesFiles:
          - charts/rails-app/values.yaml
        namespace: slot-2
        createNamespace: true
        setValueTemplates:
          image.repository: "{{.IMAGE_REPO_rails_app}}"
          image.tag: "{{.IMAGE_TAG_rails_app}}"
      - name: loki
        remoteChart: loki
        repo: https://grafana.github.io/helm-charts
        version: "6.18.0"
        valuesFiles:
          - charts/loki/values.yaml
        namespace: slot-2
        createNamespace: true
      - name: jaeger
        remoteChart: jaeger
        repo: https://jaegertracing.github.io/helm-charts
        version: "3.3.1"
        valuesFiles:
          - charts/jaeger/values.yaml
        namespace: slot-2
        createNamespace: true
      - name: fluent-bit
        remoteChart: fluent-bit
        repo: https://fluent.github.io/helm-charts
        version: "0.47.9"
        valuesFiles:
          - charts/fluent-bit/values.yaml
        namespace: slot-2
        createNamespace: true
```

Run: `skaffold dev --filename .skaffold/slot-2-test.yaml`

**Acceptance criteria:**
- Skaffold accepts the file without a parse error.
- Build artifacts are inherited from `skaffold.yaml` — no duplicate `build.artifacts` block is needed in the override file.
- Port-forwards bind to the override `localPort` values (verify with `lsof -i :5452`).
- All releases deploy into the `slot-2` namespace (verify with `kubectl get pods -n slot-2`).
- The `default` namespace slot-1 stack is unaffected if running concurrently.

**If `requires` does not compose `portForward` correctly:** Fall back to generating a self-contained full Skaffold YAML that duplicates the build stanza. Update the design accordingly before proceeding to Phase 2.

### Task 1.2 — Verify Helm release name collision avoidance

With both slot-1 (namespace `default`) and slot-2 (namespace `slot-2`) deployed simultaneously, confirm Helm treats the two `postgres` releases as distinct objects.

Run: `helm list -A`

**Acceptance criteria:**
- `helm list -A` shows `postgres` in `default` and `postgres` in `slot-2` as separate releases with no conflict.
- `kubectl get pvc -A` shows no shared PVC between slots.

### Task 1.3 — Verify Postgres hostPath isolation

Confirm that slot-2 Postgres writes to `/tmp/rails-llm-demo/postgres-slot-2` and slot-1 Postgres writes to its existing path, with no shared data.

**Acceptance criteria:**
- `ls /tmp/rails-llm-demo/` shows distinct subdirectories per slot.
- Inserting a record in slot-2's database does not appear in slot-1's database.

### Phase 1 Validation

Document findings in a brief note appended to `docs/specs/parallel-slot-port-management.md` under a `## Architecture Validation` heading. The note must state which tasks passed, any deviations from the design (e.g., full-YAML fallback required), and confirm the approach is viable before Phase 2 begins.

Delete `.skaffold/slot-2-test.yaml` before merging.

---

## Phase 2 — Static infrastructure changes

**Rationale:** These changes are independent of the script logic and have no external dependencies. They must land before `bin/use-slot` is written so the script has correct reference values to write.

### Task 2.1 — Update `.env.example`

Add the following variables to `.env.example`, replacing the existing standalone `REDIS_URL` and `OTEL_EXPORTER_OTLP_ENDPOINT` lines so there are no duplicates:

```
# Slot configuration — run bin/use-slot N to configure a parallel instance
SLOT=1

# Explicit port assignments (written by bin/use-slot; base values for slot 1)
RAILS_PORT=3000
GRAFANA_PORT=3001
LOKI_PORT=3100
OTEL_PORT=4318
DB_PORT=5432
REDIS_PORT=6379
PROMETHEUS_PORT=9090
JAEGER_UI_PORT=16686

# Full URLs constructed from the ports above (written by bin/use-slot)
REDIS_URL=redis://localhost:6379/0
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318

# Kubernetes context captured at slot setup time
K8S_CONTEXT=docker-desktop
```

**Acceptance criteria:**
- `.env.example` has exactly one definition of each variable.
- `SLOT=1` is present with a comment explaining its purpose.
- All eight port variables are present with their slot-1 base values.
- `REDIS_URL` and `OTEL_EXPORTER_OTLP_ENDPOINT` are full URLs, not bare port numbers.
- `K8S_CONTEXT` is present.

### Task 2.2 — Update `.gitignore`

Add the following block to `.gitignore`:

```
# Per-instance slot configuration (generated by bin/use-slot)
.env
.skaffold/
```

**Acceptance criteria:**
- `git status` does not show `.env` or any `.skaffold/` file as untracked after they are created.
- `.env.example` remains tracked.

### Task 2.3 — Confirm Postgres chart hostPath is overridable

Inspect `charts/postgres/values.yaml`. Verify that the hostPath value is exposed under a key (e.g., `persistence.hostPath`) that can be overridden via Helm `setValues` in the generated slot file.

If the key is not exposed, add a `persistence.hostPath` key with the current hardcoded path as its default, and reference it in `charts/postgres/templates/` wherever the hostPath appears.

**Acceptance criteria:**
- `helm template charts/postgres --set persistence.hostPath=/tmp/test` produces a manifest with `/tmp/test` as the hostPath and exits 0.
- The default value in `values.yaml` matches the current hardcoded path so slot 1 is unaffected.
- `helm template charts/postgres` (no overrides) produces output identical to the pre-change manifest.

### Phase 2 Validation

- `git diff --stat` shows only `.env.example`, `.gitignore`, and (if needed) `charts/postgres/values.yaml` and its templates.
- Create a throwaway `.env` file and confirm `git status` does not show it.
- Run `helm template charts/postgres` and confirm the output matches the pre-change manifest exactly.

---

## Phase 3 — `bin/use-slot` script

**Rationale:** This is the core deliverable. It depends on Phase 1 (known working YAML structure to generate) and Phase 2 (known variable names to write).

### Task 3.1 — Implement port resolution logic

Write `bin/use-slot` as a Ruby script (stdlib only, no gems). Implement:

**Base port table** (hardcoded constant):

```ruby
BASE_PORTS = {
  rails:        3000,
  grafana:      3001,
  loki:         3100,
  otel:         4318,
  postgres:     5432,
  redis:        6379,
  prometheus:   9090,
  jaeger_ui:    16686
}.freeze
```

**Offset formula:** `candidate = base + (slot - 1) * 20`

**Port availability check (three-tier, tried in order):**
1. `lsof -i :PORT -sTCP:LISTEN -t 2>/dev/null` — taken if output is non-empty.
2. `ss -tlnp 2>/dev/null | grep -q :PORT` — taken if grep exits 0.
3. `TCPServer.new('127.0.0.1', PORT)` — taken if `Errno::EADDRINUSE` is raised; close the socket immediately if binding succeeds.

For each service: try candidate; if taken increment by 1 and retry, up to 10 attempts. Exit 1 with a message identifying the service if no free port is found within 10 attempts.

**Acceptance criteria:**
- Binding a port manually before running the script causes that port to be skipped and the next free port to be assigned.
- Execution on Linux where `lsof` is absent falls back to `ss` without crashing.
- Exhausting 10 attempts prints a clear error naming the service and exits 1.

### Task 3.2 — Implement `.env` read/write and idempotency

**Idempotency:** If `.env` exists and contains `SLOT=N` matching the requested slot, read existing port values from `.env` and skip recomputation. Print: `Slot N already configured. Use --force to recompute.`

**`--force` flag:** Recompute ports and overwrite `.env` regardless of existing content.

**Conflict guard:** If `.env` exists with a different `SLOT=M`, prompt: `This worktree is configured for slot M. Overwrite with slot N? [y/N]`. Exit 0 cleanly if the user answers N.

**`.env` write behaviour:**
- Write `SLOT`, all eight `*_PORT` variables, `REDIS_URL` (full URL), `OTEL_EXPORTER_OTLP_ENDPOINT` (full URL), and `K8S_CONTEXT`.
- Capture `K8S_CONTEXT` via `kubectl config current-context`; exit 1 if `kubectl` is unavailable.
- Preserve any existing variables not in the script's write set (e.g., `OPENAI_API_BASE`, `LLM_MODEL`, `OTEL_ENABLED`, `OTEL_SERVICE_NAME`) by reading the existing `.env` first and merging.

**Acceptance criteria:**
- Running `bin/use-slot 2` twice without `--force` on the second run prints the idempotency message and does not modify `.env`.
- Running with `--force` recomputes and overwrites port values.
- `OPENAI_API_BASE` set by the developer survives a re-run without `--force`.
- `REDIS_URL` written to `.env` is `redis://localhost:RESOLVED_PORT/0`.
- `OTEL_EXPORTER_OTLP_ENDPOINT` written to `.env` is `http://localhost:RESOLVED_PORT`.
- `K8S_CONTEXT` matches `kubectl config current-context`.

### Task 3.3 — Implement `.skaffold/slot-N.yaml` generation

After writing `.env`, generate `.skaffold/slot-N.yaml` using the resolved ports. The file structure must match the validated skeleton from Phase 1 Task 1.1 (or the full-YAML fallback if `requires` was found not to work).

- Use `requires: [{path: ../skaffold.yaml}]` to inherit build artifacts.
- Include the full `deploy.helm.releases` list with namespace `slot-N` on every release.
- Include `setValues: {persistence.hostPath: /tmp/rails-llm-demo/postgres-slot-N}` on the postgres release only.
- Include the full `portForward` list with resolved `localPort` values and namespace `slot-N`.

For slot 1: skip generating any file. `.skaffold/` directory is not created.

**Acceptance criteria:**
- `bin/use-slot 2` creates `.skaffold/slot-2.yaml`.
- `bin/use-slot 1` does not create a `.skaffold/` directory.
- `skaffold render --filename .skaffold/slot-2.yaml` exits 0.
- All `localPort` values in the generated YAML match the corresponding values written to `.env`.
- All namespaces in the generated YAML are `slot-2`.
- The postgres release contains the `persistence.hostPath` override set to `/tmp/rails-llm-demo/postgres-2`.

### Task 3.4 — Print summary and usage hint

After a successful run, print a formatted summary:

```
Slot 2 configured.

  RAILS_PORT=3020     → http://localhost:3020
  DB_PORT=5452
  REDIS_PORT=6399
  OTEL_PORT=4338
  PROMETHEUS_PORT=9110
  GRAFANA_PORT=3021
  LOKI_PORT=3120
  JAEGER_UI_PORT=16706

  K8S_CONTEXT=docker-desktop

Start the stack:
  bin/dev

Force recompute:
  bin/use-slot 2 --force
```

Ports that were nudged from the heuristic value include a note: `REDIS_PORT=6400  (nudged — 6399 was in use)`.

**Acceptance criteria:**
- All eight resolved ports appear in the summary.
- Nudged ports are annotated.
- Summary is printed only after `.env` and the YAML file are successfully written.

### Phase 3 Validation

End-to-end smoke test (do not commit test artifacts):

1. In a worktree, run `bin/use-slot 2`.
2. Confirm `.env` contains `SLOT=2`, all eight port variables, `REDIS_URL`, `OTEL_EXPORTER_OTLP_ENDPOINT`, and `K8S_CONTEXT`.
3. Confirm `.skaffold/slot-2.yaml` exists and `skaffold render --filename .skaffold/slot-2.yaml` exits 0.
4. Run `bin/use-slot 2` again (no `--force`); confirm `.env` is unchanged and the idempotency message is printed.
5. Run `bin/use-slot 2 --force`; confirm `.env` is rewritten.
6. Bind a port manually (`ruby -e "require 'socket'; s = TCPServer.new('127.0.0.1', 6399); sleep 60" &`) and run `bin/use-slot 2 --force`; confirm `REDIS_PORT` is nudged to 6400.

---

## Phase 4 — Developer workflow scripts

**Rationale:** `bin/dev` and `bin/setup-worktree` depend on Phase 3 being complete so they can consume the `.env` and `.skaffold/slot-N.yaml` it produces.

### Task 4.1 — Rewrite `bin/dev`

Replace the current `bin/dev` (which only execs `bin/rails server`) with a bash script:

1. Source `.env` if it exists; exit 1 with `No .env found. Run bin/use-slot 1 first.` if it does not.
2. Determine the Skaffold file: slot 1 → `skaffold.yaml`; slot N > 1 → `.skaffold/slot-N.yaml`. Exit 1 with `Run bin/use-slot $SLOT first.` if the slot file does not exist.
3. Start `skaffold dev --filename $SKAFFOLD_FILE --kube-context $K8S_CONTEXT` in the background, capturing its PID.
4. Register a `trap` on `EXIT`, `INT`, and `TERM` to kill the background PID.
5. Exec `bin/rails server -p $RAILS_PORT -b 0.0.0.0` in the foreground.

No foreman. No external process manager. Plain bash only.

**Acceptance criteria:**
- Slot-1 worktree: `bin/dev` starts Rails on port 3000 and Skaffold with `skaffold.yaml`.
- Slot-2 worktree: `bin/dev` starts Rails on port 3020 and Skaffold with `.skaffold/slot-2.yaml`.
- Ctrl-C kills both processes; `ps aux | grep skaffold` shows no orphan after exit.
- Missing `.env` prints the helpful error and exits 1.
- Missing `.skaffold/slot-N.yaml` prints the helpful error and exits 1.
- `--kube-context $K8S_CONTEXT` is passed to every `skaffold` invocation.

### Task 4.2 — Update (or create) `bin/setup-worktree`

If `bin/setup-worktree` exists, append the slot setup steps after the existing worktree creation logic. If it does not exist, create it with:

1. Prompt for branch name and target directory.
2. Run `git worktree add $TARGET_DIR -b $BRANCH`.
3. Prompt: `Enter slot number for this worktree [2]: ` (default 2 if the user presses enter).
4. Run `bin/use-slot $SLOT` from within `$TARGET_DIR` (using `cd $TARGET_DIR && ../bin/use-slot $SLOT` or equivalent).

**Acceptance criteria:**
- Running `bin/setup-worktree` from the primary worktree creates a new worktree directory.
- After completion, the new worktree's `.env` has the correct `SLOT` and resolved port values.
- The new worktree's `.skaffold/slot-N.yaml` exists and passes `skaffold render`.
- No manual steps are required beyond responding to the two prompts.

### Phase 4 Validation

Full two-slot live test:

1. Primary worktree: `bin/use-slot 1`, then `bin/dev`. Confirm Rails responds on port 3000.
2. New worktree (created via `bin/setup-worktree`, slot 2): `bin/dev`. Confirm Rails responds on port 3020.
3. Both stacks running: `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000` → 200; same for port 3020.
4. `kubectl get pods -A` shows rails-app pods in both `default` and `slot-2` namespaces.
5. `helm list -A` shows no Helm release name conflicts.
6. Ctrl-C one `bin/dev`; the other continues responding.

---

## Phase 5 — Documentation and cleanup

**Rationale:** Documentation is last because the exact behaviour — especially any deviations found in Phase 1 — must be described accurately.

### Task 5.1 — Add slot convention to `docs/decisions.md`

Add a new section `## Parallel Slot Port Management` covering:

- Why slots exist: concurrent worktree development without port conflicts.
- Daily workflow: `bin/use-slot N` once per worktree, then `bin/dev` thereafter.
- Constraint: slot 1 is always the default; it uses `skaffold.yaml` directly and requires no generated files.
- That `.skaffold/` and `.env` are gitignored and instance-specific; re-run `bin/use-slot` in each new worktree.
- That `.env` and `.skaffold/slot-N.yaml` must stay in sync — do not edit port values in `.env` manually without regenerating the slot YAML.
- Escape hatch: `bin/use-slot N --force` recomputes and overwrites both files.
- Link to `docs/specs/parallel-slot-port-management.md` for design rationale.

**Acceptance criteria:**
- Section is present under the heading `## Parallel Slot Port Management`.
- All six points above are covered.
- No design rationale is duplicated from the spec doc — only conventions and prohibitions.

### Task 5.2 — Mark `future-multi-instance-ports.md` superseded

Add the following notice as the first content in `docs/specs/future-multi-instance-ports.md`:

```
> **Superseded.** See `parallel-slot-port-management.md` and
> `parallel-slot-port-management-implementation-plan.md` for the implemented design.
> Do not act on the proposals in this document.
```

**Acceptance criteria:**
- The notice is the first visible content in the file.
- The file is not deleted (history preserved).

### Task 5.3 — Linting and security pass

Run `bin/rubocop --autocorrect` if `bin/use-slot` is Ruby. Run `bin/brakeman --no-pager` and `bin/bundler-audit`. Fix any findings.

**Acceptance criteria:**
- `bin/rubocop` exits 0 with no offenses on all files touched by this feature.
- `bin/brakeman --no-pager` exits 0.
- `bin/bundler-audit` exits 0 (no new gems introduced by this feature).

### Phase 5 Validation

- `docs/decisions.md` contains `## Parallel Slot Port Management`.
- `docs/specs/future-multi-instance-ports.md` has the superseded notice as its first line.
- `bin/ci` passes in the primary worktree.

---

## Definition of Done

All of the following must be true before this feature is considered complete:

1. **`bin/use-slot N`** resolves ports with three-tier availability checking, writes `.env` with all required variables including full URLs, generates `.skaffold/slot-N.yaml` for N > 1, and is idempotent. Slot 1 writes `.env` but generates no Skaffold file.
2. **`bin/dev`** starts both Skaffold and Rails from a single command using values from `.env`. Ctrl-C kills both processes cleanly with no orphans.
3. **Two slots run concurrently** on one laptop: both serve HTTP traffic on distinct ports, pods are in separate Kubernetes namespaces, and Postgres data directories are distinct paths on the host.
4. **Port conflicts are detected before startup:** occupying a candidate port before `bin/use-slot` runs causes that port to be nudged to the next free port, not silently double-assigned.
5. **`.env` and `.skaffold/` are gitignored.** `.env.example` is committed, complete, and reflects all variables written by `bin/use-slot`.
6. **Slot 1 is unaffected:** a developer who copies `.env.example` to `.env` and runs `skaffold dev` directly continues to work as before. `bin/dev` also works for slot 1 after `bin/use-slot 1` is run once.
7. **`bin/ci` passes** in the primary worktree with no new rubocop, brakeman, or bundler-audit findings.
8. **`docs/decisions.md`** documents the slot convention, daily workflow, and the sync constraint between `.env` and `.skaffold/slot-N.yaml`.
