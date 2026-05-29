# Getting Started

This guide walks you from a fresh clone to a Grafana dashboard full of real LLM signal. It assumes you are comfortable with Kubernetes and Helm. For what each dashboard panel means, see [observability.md](observability.md).

## 1. Prerequisites

| Tool | Version |
|---|---|
| Docker Desktop (Kubernetes enabled) or k3d/kind | latest |
| `kubectl` | 1.28+ |
| `helm` | 3.x |
| `skaffold` | 2.x |
| [Ollama](https://ollama.com) | latest |
| Ruby (for `bin/load-test`) | 3.3.8 |

Pull a model and start Ollama:

```bash
ollama pull llama4
ollama serve   # localhost:11434
```

Redis is deployed by the stack but is not required — Solid Cable runs over Postgres.

## 2. Clone and configure

```bash
git clone <repo-url> && cd rails-llm-demo
```

No `.env` file is needed for the in-cluster flow — the Rails pod gets its configuration from `charts/rails-app/values.yaml`. The default points the app at `http://host.docker.internal:11434/v1`, which reaches Ollama on your host from inside Docker Desktop's cluster. On Linux/k3d, edit `OPENAI_API_BASE` in that file if `host.docker.internal` does not resolve.

## 3. Start the stack

```bash
skaffold dev
```

This builds the Rails image, deploys all charts (Postgres, Redis, Rails, kube-prometheus-stack, Loki, Jaeger, Fluent Bit), and forwards ports. **Success looks like:** Skaffold prints `Watching for changes...` and the port-forward list below.

The stack occupies these fixed ports — if any are already in use, Skaffold's port-forward will fail. Running multiple instances on one machine is not yet supported (see the [future sprint note](specs/future-multi-instance-ports.md)).

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

## 4. Verify the app

Open <http://localhost:3000>. You should see the "Your Chats" page with the "Rails LLM observability demo" tagline. Migrations ran automatically when the container booted — there is no manual database step.

**What you can see now:** create a chat, send a message, and watch the assistant reply stream in. That single message already produced a trace, metrics, and a log line.

## 5. Seed historical data

Run the seed task **inside the cluster** so its signal is scraped by Prometheus and collected by Fluent Bit:

```bash
kubectl exec -it deploy/rails-app -- bin/rails demo:seed
```

This creates five demo chats and fires their messages through the full LLM stack. Running it from your host instead would produce signal that the in-cluster Prometheus and Fluent Bit never see.

**What you can see now:** open Grafana (next step) and the panels will already have data.

## 6. Explore Grafana

Open <http://localhost:3001> and log in with **admin / admin**. The **LLM Overview** dashboard is pre-provisioned and all three data sources (Prometheus, Loki, Jaeger) are connected automatically.

For a panel-by-panel explanation, see [observability.md](observability.md#grafana-llm-dashboard).

**What you can see now:** request latency percentiles, token usage over time, error rate, and job duration — populated from the seed data.

## 7. Run the scenario

```bash
kubectl exec -it deploy/rails-app -- bin/rails demo:scenario
```

This runs four requests in sequence: **normal → slow → error → recovery**. Each step prints what signal to expect.

**What you can see now:**
- The **LLM Request Latency** panel shows a p95 spike on the *slow* step.
- The **LLM Error Rate** panel shows a red bar on the *error* step, then recovers.
- In Jaeger (<http://localhost:16686>), each step is a full request → job → LLM trace.

## 8. (Optional) Sustained load

To make rate graphs and percentile histograms meaningful, drive sustained traffic from your host:

```bash
bin/load-test --stub --duration 60s     # synthetic latency, no Ollama needed
bin/load-test --real --duration 60s      # full stack through Ollama
```

`--real` mode runs a pre-flight check and exits with a clear message if Ollama is unreachable.

**What you can see now:** the latency histogram fills out and the request-rate panels climb for the duration of the run.
