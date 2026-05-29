# rails-llm-demo

A Rails 8.1 chatbot that demonstrates end-to-end observability for a local LLM workload. Every message becomes a distributed trace (Jaeger), a set of metrics (Prometheus), and a structured log line (Loki) — all visible in a pre-provisioned Grafana dashboard. The whole stack — app, databases, and observability tooling — runs in Kubernetes via Skaffold.

The companion blog post targets platform engineers evaluating local LLM tooling. To run the demo yourself, follow **[docs/getting-started.md](docs/getting-started.md)**.

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Docker Desktop | latest | With Kubernetes enabled (or another local cluster: k3d, kind) |
| `kubectl` | 1.28+ | |
| `helm` | 3.x | Skaffold invokes Helm to deploy the charts |
| `skaffold` | 2.x | Orchestrates build + deploy + port-forward |
| [Ollama](https://ollama.com) | latest | Any OpenAI-compatible endpoint works; Ollama is the easiest local option |
| Ruby | 3.3.8 | Only needed to run `bin/load-test` from the host |

Redis is deployed by the stack but is **not required** for core features — Solid Cable runs over Postgres. It is present for optional experimentation only.

Pull a model before starting:

```bash
ollama pull llama4
ollama serve   # listens on localhost:11434
```

## Quick start

```bash
git clone <repo-url> && cd rails-llm-demo
skaffold dev      # builds the image, deploys everything, forwards ports
```

`skaffold dev` brings up Postgres, Redis, the Rails app, and the full observability stack. Database migrations run **automatically** when the Rails container boots (`bin/docker-entrypoint` runs `db:prepare`) — there is no manual `db:setup` step. When the app is ready, open <http://localhost:3000>.

The in-cluster app reaches Ollama on your host via `host.docker.internal:11434` (configured in `charts/rails-app/values.yaml`). On Docker Desktop this works out of the box; on Linux/k3d you may need to adjust the host address.

## Ports

The stack occupies these fixed ports. Check for conflicts before starting — running multiple instances on one machine is not yet supported (see `docs/specs/future-multi-instance-ports.md`).

| Port | Service |
|---|---|
| 3000 | Rails app |
| 3001 | Grafana |
| 9090 | Prometheus |
| 16686 | Jaeger UI |
| 4318 | Jaeger OTLP collector (HTTP) |
| 3100 | Loki |
| 5432 | Postgres |
| 6379 | Redis |

## Generate signal

Run these against a running stack to populate the dashboards. Because Prometheus scrapes the in-cluster pod and Fluent Bit collects pod logs, the rake tasks must run **inside the cluster**:

```bash
kubectl exec -it deploy/rails-app -- bin/rails demo:seed       # historical chat data
kubectl exec -it deploy/rails-app -- bin/rails demo:scenario   # normal → slow → error → recovery
```

The load generator runs from the host (it drives the app over HTTP):

```bash
bin/load-test --stub                 # synthetic latency, no Ollama needed
bin/load-test --real --duration 60s  # full stack through Ollama
```

## Documentation

- **[docs/getting-started.md](docs/getting-started.md)** — step-by-step walkthrough from clone to populated Grafana
- **[docs/observability.md](docs/observability.md)** — what's instrumented, dashboard panels, Helm chart versions
- **[docs/architecture.md](docs/architecture.md)** — component diagram and data flow

## Tests

```bash
bin/ci          # full local CI: tests, rubocop, brakeman, bundler-audit
bin/rails test  # unit + integration tests only
```
