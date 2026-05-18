# Observability

The app ships with a Docker Compose stack: Jaeger (traces), Prometheus (metrics), Loki (logs), Grafana (dashboards), and Fluent Bit (log shipping).

## Start the stack

```bash
docker compose -f docker-compose.observability.yml up -d
```

Then enable tracing in `.env`:

```
OTEL_ENABLED=true
```

Restart `bin/rails server`. Traces appear in Jaeger immediately; Prometheus scrapes metrics every 15s.

## Services

| Service | URL | Purpose |
|---|---|---|
| Grafana | http://localhost:3000 | Unified dashboards |
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
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | OTLP HTTP collector (Jaeger) |
| `OTEL_SERVICE_NAME` | `rails-llm-demo` | Service name shown in traces |

## Stop the stack

```bash
docker compose -f docker-compose.observability.yml down
```
