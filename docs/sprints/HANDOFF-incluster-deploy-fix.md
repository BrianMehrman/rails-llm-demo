# HANDOFF: Make in-cluster `skaffold dev` actually work

**Date:** 2026-05-29
**Branch:** `feature/fix-incluster-deploy` (worktree: `.claude/worktrees/agent-1780078421`, based on `origin/main`)
**Trigger:** User reported "the instructions do not work" — `skaffold dev --port-forward` fails from a clean cluster.

> **➜ START HERE NEXT SESSION:** All nine known bugs are now fixed and the cluster is healthy (rails-app `GET /` → 200). Do a clean `skaffold delete && skaffold run` to confirm the image-baked fixes (#8 lograge, #9 db:prepare initContainer) work from scratch, then walk the demo path (Ollama → Jaeger/Prometheus/Loki/Grafana) and open the PR. See "Next steps" at the bottom.

## Root meta-cause

The **in-cluster production deployment has never run end-to-end.** Earlier work (and the merged blog-post-prep docs) assumed it worked. It doesn't — booting it surfaces one untested layer at a time. So far **four** stacked bugs, each a distinct root cause. Each fix reveals the next.

## The bugs (count grew during verification)

### 1. CRD ordering — FIXED & VERIFIED
`skaffold.yaml` deployed `rails-app` before `kube-prometheus-stack`, but rails-app's `ServiceMonitor` (`charts/rails-app/templates/service-monitor.yaml`) needs the `monitoring.coreos.com/v1` CRD that kube-prometheus-stack installs. Error: `no matches for kind "ServiceMonitor"`.
**Fix:** moved `kube-prometheus-stack` release before `rails-app` in `skaffold.yaml`.
**Verified:** rails-app helm release installs; no ServiceMonitor error.

### 2. Jaeger all-in-one misconfig — FIXED & VERIFIED
`charts/jaeger/values.yaml` mixed all-in-one mode with production `collector:`/`query:` config, so the chart rendered duplicate name-colliding `jaeger-collector`/`jaeger-query` Services (one with an unnamed OTLP-grpc port) + a duplicate `COLLECTOR_OTLP_ENABLED` env. Errors: `Service "jaeger-collector" is invalid: spec.ports[2].name: Required value` and `duplicate entries for key COLLECTOR_OTLP_ENABLED`.
**Fix:** removed the redundant `allInOne.extraEnv` and set `collector.enabled: false` + `query.enabled: false` (kept `agent.enabled: false`). Verified via `helm template`: one of each service, 4318 + 16686 exposed, no unnamed ports, single env var.
**Verified:** jaeger helm release installs in a full `skaffold run`.

### 3. Missing `cache` database (Solid Cache) — FIXED, app now boots
Production uses `:solid_cache_store` (`config/environments/production.rb:50`) and `config/cache.yml` sets `database: cache`, but `config/database.yml` had no `cache` role → `AdapterNotSpecified: cache database not configured for production` at eager-load.
**Fix:** added `cache` role to `config/database.yml` (development/test/production), mirroring queue/cable, + `CACHE_DATABASE_URL` in `charts/rails-app/values.yaml` ConfigMap. Schema loads from existing `db/cache_schema.rb` by convention; Rails auto-maps `CACHE_DATABASE_URL` to the `cache` db (same mechanism queue/cable use in production — note the production section has no explicit `url:` keys).
**Verified:** the rebuilt pod boots past the cache crash — it now serves HTTP (see bug #4).

### 4. Missing `/up` health route — NOT FIXED (current rails-app blocker)
`charts/rails-app/templates/deployment.yaml` liveness+readiness probes hit `path: /up` (lines 29, 36), but `config/routes.rb` has **no `/up` route**. Pod logs: `ActionController::RoutingError (No route matches [GET] "/up")` → probes fail → CrashLoopBackOff.
**Proposed fix:** add the Rails 8 health route to `config/routes.rb`:
```ruby
get "up" => "rails/health#show", as: :rails_health_check
```
(Confirm `Rails::HealthController` / `rails/health#show` is available — it ships with Rails 8. Alternatively point the probes at an existing route, but the health route is the right fix.)

### 5. `node-exporter` cannot run on Docker Desktop — FIXED & VERIFIED (re-fixed: wrong key)
`prometheus-node-exporter` from kube-prometheus-stack crash-loops with `path / is mounted on / but it is not a shared or slave mount`. It wants a host `/` shared/slave bind-mount that Docker Desktop's runtime forbids — well-known incompatibility. node-exporter only collects host-level metrics (CPU/disk/network), which are not part of this demo's app-level LLM signal.
**First attempt was wrong** — set `prometheus-node-exporter.enabled: false`, which only *configures* the subchart. The DaemonSet still deployed and crash-looped (confirmed live).
**Root cause of the miss:** kube-prometheus-stack gates the subchart via the dependency `condition: nodeExporter.enabled` in its Chart.yaml. The correct disable key is the top-level `nodeExporter.enabled`, not `prometheus-node-exporter.enabled`.
**Fix:** `charts/kube-prometheus-stack/values.yaml` now uses:
```yaml
nodeExporter:
  enabled: false
```
**Verified:** deleted the live DaemonSet; no node-exporter pod remains. On next `skaffold run` it should not be recreated.

### 6. `fluent-bit` CrashLoopBackOff — FIXED, awaiting redeploy
`fluent-bit-<hash>` (`charts/fluent-bit/values.yaml`) was in CrashLoopBackOff after deploy.
**Root cause:** The fluent/fluent-bit chart v0.47.9 (Fluent Bit 3.1.7) ships a default liveness probe at `GET /api/v1/health` on port 2020. Our `[SERVICE]` block did not include `HTTP_Server On` / `HTTP_Port 2020`, so Fluent Bit never opened that port. The liveness probe timed out → k8s killed and restarted the pod on every cycle.
**Fix:** Added `HTTP_Server On`, `HTTP_Listen 0.0.0.0`, `HTTP_Port 2020` to the `[SERVICE]` section in `charts/fluent-bit/values.yaml`.
**Verified:** after redeploy, `fluent-bit` pod is `Running 1/1`.

### 7. Postgres `initdb: directory exists but is not empty` — FIXED & VERIFIED
On a fresh `skaffold run`, `postgres-0` CrashLoopBackOff: `initdb: error: directory "/var/lib/postgresql/data/pgdata" exists but is not empty`. A previous deploy's initdb was interrupted partway (created `base/` + `global/` but never wrote `PG_VERSION`), leaving a partial cluster in the hostPath volume. The postgres entrypoint sees no `PG_VERSION`, retries initdb, and refuses because the dir is non-empty.
**Why it persisted:** `bin/reset-db` (the documented recovery tool) had two bugs and never actually cleared the data:
  - It `rm -rf`'d `/tmp/postgres-rails/postgres`, but the chart's hostPath is `/tmp/rails-llm-demo/postgres` (`charts/postgres/values.yaml`). The real dir was never touched.
  - Its `kubectl` label selectors used `app.kubernetes.io/name=postgresql` (and fallback `app=postgres`); the chart emits `app.kubernetes.io/name=postgres`. The restart/wait steps matched nothing.
**Fix:** corrected `bin/reset-db` — hostPath now `/tmp/rails-llm-demo/postgres`, selectors now `app.kubernetes.io/name=postgres,app.kubernetes.io/instance=postgres`. (Note: on Docker Desktop the mac's `/tmp` IS shared into the VM, so the host-side `rm -rf` does reach the pod's data — verified.)
**Verified:** cleared the stale dir + deleted `postgres-0`; it reinitialised cleanly and is `Running 1/1`.

### 8. lograge crashes on every request (`undefined method 'utc' for a Float`) — FIXED, awaiting redeploy
`config/initializers/lograge.rb:6` called `event.time.utc.iso8601(3)`. In Rails 8.1, `ActiveSupport::Notifications::Event#time` returns a `Float`, not a `Time`, so every request logged `NoMethodError: undefined method 'utc' for an instance of Float` (the request still served, but structured logs were lost).
**Fix:** use `Time.now.utc.iso8601(3)` (emit-time wall clock; precise span timing is carried by trace_id/span_id in `custom_payload`). Format still matches the Fluent Bit `rails_json` parser.
**Verification:** baked into the image — confirm after `skaffold run` that rails-app logs no longer show the lograge error.

### 9. App schema never loaded → `relation "chats" does not exist` (500) — FIXED & VERIFIED
The rails-app pod reached `Running` (because `/up` doesn't touch the DB), but `GET /` returned 500: `PG::UndefinedTable: relation "chats" does not exist`. Nothing in the deploy created the queue/cable/cache databases or loaded any schema. `POSTGRES_DB` only creates the primary `chatbot_development` database, empty.
**True root cause:** a prior design doc (`docs/specs/2026-05-25-blog-post-prep-design.md:55`) *claimed* `bin/docker-entrypoint` runs `db:prepare` automatically on boot. It never did — the guard `[ "${@: -2:1}" == "./bin/rails" ] && [ "${@: -1:1}" == "server" ]` only matches a bare `./bin/rails server`, but the real CMD ends in `-b 0.0.0.0 -p 3000`, so the branch was dead code. Documented-as-working, never run.
**Fix (run-once, replica-safe):** schema prep now runs in a **Helm `pre-install`/`pre-upgrade` hook Job** (`charts/rails-app/templates/db-prepare-job.yaml`), NOT per-pod. Helm blocks the rollout until the Job completes, so the app pods start with the schema already present. Critically this runs **exactly once per release regardless of `replicaCount`** — a per-pod initContainer (the first attempt) would have multiple web replicas racing `CREATE`/migrate. "An array of many is the same as an array of one": multi-instance is on the roadmap, so the single instance is designed as an example of the many. The Job's env is rendered from the same `.Values.env` map as the ConfigMap (one source of truth); it can't use `envFrom` because pre-install hooks run before the normal ConfigMap exists. The dead `db:prepare` branch in `bin/docker-entrypoint` was removed.
**Verified from scratch:** cleared postgres, `skaffold run` → `rails-app-db-prepare` Job `Complete 1/1` (created `chatbot_development_queue/_cable/_cache`), app pod started after it, `GET /` → **200**, lograge errors: 0.

## Commits on this branch
- `3cd2637` fix(deploy): bugs #1, #2, #3
- handoff doc commit
- `<prev commit>` fix(kps): disable node-exporter on Docker Desktop (bug #5, first/wrong attempt)
- `37d0a47` fix(routes): add /up health route so k8s probes don't 404 (bug #4)
- `1a35f53` fix(fluent-bit): enable HTTP server for liveness probe (bug #6)
- `68ce9da` fix(deploy): node-exporter key, postgres reset, lograge, db:prepare initContainer (bugs #5 re-fix, #7, #8, #9)
- `<this commit>` refactor(deploy): run db:prepare once per release via Helm hook Job instead of per-pod (replica-safe); remove dead entrypoint branch
**WIP — not yet PR'd.**

## Verification status
- Full `skaffold run`: all releases install. ✓
- `rails-app`: `Running 1/1`; `GET /up` → 200, `GET /` → 200 after schema load. ✓ (lograge + initContainer fixes baked into image — confirm on next clean `skaffold run`)
- `fluent-bit`: `Running 1/1`. ✓
- `postgres-0`: `Running 1/1` after stale-data clear. ✓
- `node-exporter`: DaemonSet deleted, no pod. ✓ (confirm not recreated on next `skaffold run`)

## Next steps (in order)
1. **➜ START HERE:** Clean redeploy to confirm the image-baked fixes (lograge #8, db:prepare initContainer #9) and the value/chart fixes (#5, #6) all work from scratch:
   `skaffold delete` then `skaffold run`. Confirm: all pods `Running`, no `node-exporter` pod, `rails-app` init passes `db-prepare`, `GET /` → 200, rails-app logs clean of the lograge error.
2. Then verify the actual demo path (still untested end-to-end):
   - App reachable at `http://localhost:3000` (`skaffold dev --port-forward`).
   - App reaches Ollama via `host.docker.internal:11434` — send a message, confirm a reply.
   - Traces reach Jaeger (`http://localhost:16686`), metrics in Prometheus, logs in Loki.
   - `kubectl exec -it deploy/rails-app -- bin/rails demo:seed` populates Grafana.
3. Open a PR (PR-only rule — never merge to main locally).

## Resume / cluster state
- Resume: `cd` to the worktree, `git checkout feature/fix-incluster-deploy` (also pushed to `origin`).
- Cluster is currently **fully up and healthy** (all pods Running; node-exporter removed; schema loaded). The image still runs the pre-fix lograge — a clean redeploy picks up #8/#9.
- To relieve the machine: `skaffold delete` (from the worktree).
- Ollama is installed on the host; ensure `ollama serve` + `ollama pull llama4` for the real path.

## Unrelated note
`bin/rubocop` reports 68 offenses, all in generated `db/*_schema.rb` files — pre-existing on `main`, not from this work.
