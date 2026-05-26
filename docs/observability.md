# Observability

The app ships with a full observability stack deployed into Kubernetes via Skaffold: Jaeger (traces), Prometheus (metrics), Loki (logs), Grafana (dashboards), and Fluent Bit (log shipping).

## Start the stack

The observability stack starts automatically with the rest of the local Kubernetes environment:

```bash
skaffold dev
```

Skaffold deploys all services — Postgres, Redis, the Rails app, and the full observability stack — and sets up port-forwards automatically.

Then enable tracing in `.env`:

```
OTEL_ENABLED=true
```

Restart `bin/rails server`. Traces appear in Jaeger immediately; Prometheus scrapes metrics every 15s via the `ServiceMonitor` resource in `charts/rails-app/templates/service-monitor.yaml`.

## Services

| Service | URL | Purpose |
|---|---|---|
| Grafana | http://localhost:3001 | Unified dashboards (admin / admin) |
| Jaeger | http://localhost:16686 | Distributed trace viewer |
| Prometheus | http://localhost:9090 | Metrics query |
| Loki | http://localhost:3100 | Log aggregation |

## What's instrumented

- **HTTP requests** — via `opentelemetry-instrumentation-rails`
- **ActiveRecord queries** — via `opentelemetry-instrumentation-active_record`
- **LLM calls** — manual span in `LlmClient#chat`, labelled with model name and response length
- **LLM duration** — Prometheus histogram `llm_request_duration_seconds{model, status}`

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `OTEL_ENABLED` | `false` | Master switch — set `true` to activate |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://jaeger-collector.default.svc.cluster.local:4318` | OTLP HTTP collector (Jaeger in-cluster). Set to `http://localhost:4318` when running the Rails server outside Kubernetes. |
| `OTEL_SERVICE_NAME` | `rails-llm-demo` | Service name shown in traces |

## Helm chart versions

| Chart | Repository | Version |
|---|---|---|
| `kube-prometheus-stack` | prometheus-community | 65.1.1 |
| `loki` | grafana | 6.18.0 |
| `jaeger` | jaegertracing | 3.3.1 |
| `fluent-bit` | fluent | 0.47.9 |

## Architecture

- **Prometheus** scrapes the Rails `/metrics` endpoint via a `ServiceMonitor` resource (`charts/rails-app/templates/service-monitor.yaml`). The `kube-prometheus-stack` is configured with `serviceMonitorSelector: {}` so it discovers all `ServiceMonitor` resources in the cluster.
- **Fluent Bit** runs as a DaemonSet, collecting logs from all pod containers via `/var/log/containers/` and forwarding to Loki at `loki.default.svc.cluster.local:3100`.
- **Jaeger** runs in all-in-one mode with in-memory storage — suitable for local development. The Rails app sends OTLP traces directly to the in-cluster collector at `http://jaeger-collector.default.svc.cluster.local:4318`.
- **Grafana** is pre-configured with anonymous access disabled — log in with `admin` / `admin`.

## Grafana LLM Dashboard

After `skaffold dev` is running, open Grafana at http://localhost:3001 and log in with **admin / admin**.

The **LLM Overview** dashboard is pre-provisioned — no manual import or setup is required. It appears under Dashboards as soon as Grafana starts.

### Data sources

All three data sources are connected automatically via Helm values:

| Data Source | Type | In-cluster URL |
|---|---|---|
| Prometheus | prometheus | (default, managed by kube-prometheus-stack) |
| Loki | loki | `http://loki.default.svc.cluster.local:3100` |
| Jaeger | jaeger | `http://jaeger-query.default.svc.cluster.local:16686` |

### Dashboard panels

The LLM Overview dashboard contains four panels:

| Panel | Metric | Description |
|---|---|---|
| LLM Request Latency | `llm_request_duration_seconds` | p50 / p95 / p99 HTTP-level latency for LLM requests |
| Token Usage Over Time | `llm_tokens_total` | Rate of prompt, completion, and total tokens over time |
| LLM Error Rate | `llm_request_duration_seconds_count{status="error"}` | Errors per second from failed LLM requests |
| Job Duration | `llm_job_duration_seconds` | p50 / p95 background job processing time |

The dashboard JSON source is at `charts/kube-prometheus-stack/dashboards/llm-overview.json` and is provisioned into Grafana via the `dashboards` section of `charts/kube-prometheus-stack/values.yaml`.

## Stop the stack

```bash
# Stop skaffold dev with Ctrl+C — it will clean up all Kubernetes resources
```

## Demo Seed Task

Run the seed task to populate the app with realistic chat history and fire it through the full LLM stack:

```bash
bin/rails demo:seed
```

This creates 5 demo chats with realistic conversation history. Each message is processed through `LlmResponseJob` synchronously, producing traces in Jaeger, metrics in Prometheus, and structured logs in Loki. The task is idempotent — running it twice skips creation if demo chats already exist.

**Prerequisites:** `skaffold dev` running with `OPENAI_API_BASE` pointing to a live Ollama endpoint with a model pulled.

## Demo Scenario Task

Run the scenario task to trigger a scripted sequence of observable events:

```bash
bin/rails demo:scenario
```

This runs four requests in sequence, each designed to produce distinct signal in the Grafana dashboard:

| Step | What it does | Signal to watch |
|------|-------------|-----------------|
| Normal | Short prompt, baseline latency | Green in error rate panel |
| Slow | 200+ word prompt for high token count | Spike in p95 latency panel |
| Error | Unreachable host override | Red bar in error rate panel |
| Recovery | Short prompt back to normal | Latency returns to baseline |

OTEL spans are flushed between each step so each trace lands in Jaeger before the next starts.

**Prerequisites:** `skaffold dev` running with `OPENAI_API_BASE` pointing to a live Ollama endpoint.
