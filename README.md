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

There are two ways to run the stack locally.

### Local development (recommended) — `bin/dev`

```bash
git clone <repo-url> && cd rails-llm-demo
bin/dev
```

`bin/dev` is a single command. It brings up **one shared dependency stack** (Postgres, Redis, and the observability tooling) in Kubernetes, then runs the Rails server **locally** against it. On first run it assigns this worktree a "slot", creates its databases, and starts Rails. Open <http://localhost:3000>.

The local Rails server reaches Ollama directly at `localhost:11434` (via `OPENAI_API_BASE`).

#### Running multiple worktrees in parallel

Each worktree gets its own Rails port and its own databases while sharing the one dependency stack, so you can run several branches at once:

```bash
git worktree add ../feature-x -b feature-x
cd ../feature-x && bin/dev        # auto-assigns the next slot: Rails on :3010 with its own databases
```

Slots are assigned first-come (slot 1 → `:3000`, slot 2 → `:3010`, …) and recorded in a registry shared across worktrees. `bin/use-slot --list` shows the assignments; `bin/use-slot --release` frees one before you remove a worktree. See **[docs/specs/parallel-worktree-shared-deps-plan.md](docs/specs/parallel-worktree-shared-deps-plan.md)**.

### Full in-cluster deploy — `skaffold dev`

```bash
skaffold dev      # builds the image, deploys EVERYTHING including the Rails app, forwards all ports
```

This deploys the Rails app into Kubernetes too (not just the dependencies) and forwards every port below. Migrations run **automatically** when the container boots (`bin/docker-entrypoint` runs `db:prepare`). Use it to test the containerized app or a production-like topology. The in-cluster app reaches Ollama via `host.docker.internal:11434` (configured in `charts/rails-app/values.yaml`).

## Ports

With `bin/dev`, only the **Rails port varies per worktree** (slot 1 → `3000`, slot 2 → `3010`, …); the shared dependencies stay on fixed localhost ports:

| Port | Service | Exposed by |
|---|---|---|
| 3000 (+ slot offset) | Rails app | both |
| 3001 | Grafana (view Loki logs & Jaeger traces here) | both |
| 9090 | Prometheus | both |
| 5432 | Postgres | both |
| 6379 | Redis | both |
| 16686 | Jaeger UI | `skaffold dev` only |
| 4318 | Jaeger OTLP collector (HTTP) | `skaffold dev` only |
| 3100 | Loki | `skaffold dev` only |

With `bin/dev`, Loki and Jaeger run in-cluster and are viewed through Grafana's pre-provisioned data sources; their direct ports (and the OTLP collector) are forwarded only by the `skaffold dev` path.

## Generate signal

> **Use the `skaffold dev` (in-cluster) path for the observability demo.** Prometheus
> scrapes the in-cluster pod and Fluent Bit collects pod logs, so full metrics + logs only
> flow when the Rails app runs in Kubernetes. The local `bin/dev` path is for app
> development and parallel worktrees; a locally-run Rails server is not scraped/collected by
> the in-cluster tooling.

Run these against the in-cluster app to populate the dashboards:

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
