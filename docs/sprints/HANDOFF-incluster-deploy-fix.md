# HANDOFF: Make in-cluster `skaffold dev` actually work

**Date:** 2026-05-29
**Branch:** `feature/fix-incluster-deploy` (worktree: `.claude/worktrees/agent-1780078421`, based on `origin/main`)
**Trigger:** User reported "the instructions do not work" — `skaffold dev --port-forward` fails from a clean cluster.

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

### 5. `node-exporter` cannot run on Docker Desktop — FIXED, awaiting redeploy
`prometheus-node-exporter` from kube-prometheus-stack crash-loops with `Error response from daemon: path / is mounted on / but it is not a shared or slave mount`. It wants a host `/` shared/slave bind-mount that Docker Desktop's runtime forbids — well-known incompatibility. node-exporter only collects host-level metrics (CPU/disk/network), which are not part of this demo's app-level LLM signal.
**Fix:** disabled in `charts/kube-prometheus-stack/values.yaml`:
```yaml
prometheus-node-exporter:
  enabled: false
```
**Verification:** on next `skaffold run`, no `prometheus-node-exporter` DaemonSet pod should be created.

### 6. `fluent-bit` CrashLoopBackOff — NOT INVESTIGATED
`fluent-bit-<hash>` (`charts/fluent-bit/values.yaml`) is in CrashLoopBackOff after deploy. Its logs show normal inotify-watch behavior on container log files, not a fatal startup error — suggesting a probe/config issue (probe failing or fluent-bit exiting cleanly on some condition that k8s interprets as crash). Not yet investigated. Likely candidates: a liveness/readiness probe targeting an endpoint Fluent Bit doesn't expose, or a Loki-output config rejecting its config on this Loki version.

## Commits on this branch
- `3cd2637` fix(deploy): bugs #1, #2, #3
- handoff doc commit
- `<this commit>` fix(kps): disable node-exporter on Docker Desktop (bug #5)
**WIP — not yet PR'd.**

## Verification status
- `helm template` for jaeger: clean. ✓
- Full `skaffold run`: all 7 releases install (postgres, redis, kube-prometheus-stack, rails-app, loki, jaeger, fluent-bit). ✓
- rails-app pod: boots, but CrashLoopBackOff due to bug #4 (`/up` probes). ✗

## Next steps (in order)
1. Add the `/up` route (bug #4). Verify `bin/rails routes | grep up` shows it.
2. Investigate fluent-bit CrashLoopBackOff (bug #6) — `kubectl describe pod -l app.kubernetes.io/name=fluent-bit` and `kubectl logs ds/fluent-bit --previous`.
3. Redeploy: `skaffold run` (rebuilds image — `routes.rb` is baked in). Confirm `kubectl get pods` shows `rails-app 1/1 Running`, no `node-exporter` pod, and `fluent-bit` Running.
4. Then verify the actual demo path (still untested):
   - App reachable at `http://localhost:3000` (needs `skaffold dev --port-forward`).
   - App reaches Ollama via `host.docker.internal:11434` — send a message, confirm a reply.
   - Traces reach Jaeger (`http://localhost:16686`), metrics in Prometheus, logs in Loki.
   - `kubectl exec -it deploy/rails-app -- bin/rails demo:seed` populates Grafana.
5. Commit bug #4 + #6 fixes, then open a PR (PR-only rule — never merge to main locally).

## Resume / cluster state
- Resume: `cd` to the worktree, `git checkout feature/fix-incluster-deploy` (also pushed to `origin`).
- Cluster currently has the partial deploy up; rails-app is CrashLoopBackOff. To relieve the machine: `skaffold delete` (from the worktree).
- Ollama is installed on the host; ensure `ollama serve` + `ollama pull llama4` for the real path.

## Unrelated note
`bin/rubocop` reports 68 offenses, all in generated `db/*_schema.rb` files — pre-existing on `main`, not from this work.
