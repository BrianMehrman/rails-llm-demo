# Sprint Execution Plan

This document defines how stories are parallelized across agents. Each wave is a merge point — all worktrees in a wave complete and merge before the next wave opens.

---

## Worktree Naming Convention

Branch names follow `feature/<story-id>-<slug>`. Open each worktree from the tip of `main` (or from the previous wave's merge commit).

---

## Wave 1 — 4 parallel agents

All four stories have no file conflicts and no logical dependencies on each other. Open each from the current `main`.

| Agent | Worktree branch | Story | Key files |
|---|---|---|---|
| A | `feature/1-1-dockerize` | 1-1: Dockerize Rails App | `Dockerfile`, `charts/rails-app/`, `skaffold.yaml`, `config/database.yml` |
| B | `feature/1-3-token-counting` | 1-3: Token Counting in LlmClient | `app/services/llm_client.rb`, its test |
| C | `feature/2-1a-lograge-setup` | 2-1a: Lograge Setup | `Gemfile`, `config/initializers/lograge.rb` |
| D | `feature/3-2-load-generator` | 3-2: Load Generator | `bin/load-test` |

Merge all four into `main` before opening Wave 2.

---

## Wave 2 — 2 parallel agents

Both stories depend on Wave 1 being merged. They do not share files.

| Agent | Worktree branch | Story | Key files |
|---|---|---|---|
| A | `feature/1-2-observability-infra` | 1-2: Migrate Observability Stack to Kubernetes | `charts/kube-prometheus-stack/`, `charts/loki/`, `charts/jaeger/`, `charts/fluent-bit/`, `skaffold.yaml`, removes Docker Compose files |
| B | `feature/1-4-job-observability` | 1-4: Job Observability | `app/jobs/llm_response_job.rb`, its test |

Merge both into `main` before opening Wave 3.

---

## Wave 3 — 2 parallel agents

Both stories depend on Wave 2 being merged. They do not share files.

| Agent | Worktree branch | Story | Key files |
|---|---|---|---|
| A | `feature/2-1b-job-logging` | 2-1b: Job Logging and Fluent Bit Configuration | `app/jobs/llm_response_job.rb`, `charts/fluent-bit/values.yaml` |
| B | `feature/2-2-grafana-dashboards` | 2-2: Grafana LLM Dashboard via Helm Provisioning | `charts/kube-prometheus-stack/values.yaml`, `charts/kube-prometheus-stack/dashboards/llm-overview.json`, `docs/observability.md` |

Merge both into `main` before opening Wave 4.

---

## Wave 4 — sequential, same branch

These two stories share `lib/tasks/demo.rake` (3-1 creates it, 3-3 extends it) and `docs/observability.md`. Run one after the other on `main`.

| Order | Story | Key files |
|---|---|---|
| 1 | 3-1: Seed Script | `lib/tasks/demo.rake` (create), `docs/observability.md` |
| 2 | 3-3: Scenario Script | `lib/tasks/demo.rake` (extend), `docs/observability.md` |

---

## Dependency Summary

```
Wave 1: 1-1 ──┐
        1-3 ──┤ merge → Wave 2: 1-2 ──┐ merge → Wave 3: 2-1b ──┐ merge → Wave 4: 3-1 → 3-3
       2-1a ──┤                 1-4 ──┘                  2-2 ──┘
        3-2 ──┘
```

Story 3-2 (load generator) is complete after Wave 1 and requires no further work.
