> **Superseded.** See `parallel-slot-port-management.md` and
> `parallel-slot-port-management-implementation-plan.md` for the implemented design.
> Do not act on the proposals in this document.

# Future Sprint: Multi-Instance Port Configurability

**Status:** Superseded — implemented as parallel slot port management.
**Origin:** Surfaced during blog-post-prep journey audit (see `2026-05-25-blog-post-prep-design.md`).

## Problem

Every port in the stack is hardcoded:

| Port | Service |
|---|---|
| 3000 | Rails app |
| 3001 | Grafana |
| 9090 | Prometheus |
| 16686 | Jaeger UI |
| 4318 | Jaeger OTLP collector |
| 3100 | Loki |
| 5432 | Postgres |
| 6379 | Redis |

These are defined in `skaffold.yaml` (port-forward block) and the various `charts/*/values.yaml`. A developer who runs another Rails app on 3000, another Grafana on 3001, or a second copy of this stack hits a silent port-forward conflict with no clean override.

## Proposed solution

Make every port configurable via environment variables, with the current values as defaults:

`RAILS_PORT`, `GRAFANA_PORT`, `PROMETHEUS_PORT`, `JAEGER_PORT`, `JAEGER_OTLP_PORT`, `LOKI_PORT`, `DB_PORT`, `REDIS_PORT`.

Affects:
- `skaffold.yaml` — template the `localPort` values from env
- `charts/*/values.yaml` — where service ports are referenced
- `.env.example` — document the new variables
- `README.md` / `docs/getting-started.md` — note how to shift ports

This is purely a configuration-surface change — no behavior changes.

## Why it matters

Platform engineers commonly run several stacks at once. The current design forces manual edits to Helm values and Skaffold config to coexist, which undercuts the "zero-manual-configuration" story the demo is built around.
