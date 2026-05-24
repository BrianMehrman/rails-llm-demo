# Observability Enhancement Design

**Date:** 2026-05-24
**Status:** Planned
**Goal:** Produce a complete, compelling observability demo for a blog post targeting platform engineers, showing what you can see when running an LLM locally using a Rails app as the workload.

---

## Context

The app is a Rails 8.1 chatbot that calls any OpenAI-compatible LLM endpoint (Ollama, LM Studio, etc.). It ships with a four-tool observability stack: Jaeger (traces), Prometheus (metrics), Loki (logs), Grafana (dashboards). The blog post targets three audiences — Rails developers new to observability, backend developers new to LLMs, and platform engineers evaluating local LLM tooling — with the platform engineer as the primary audience.

The approach is **LLM story first**: build outward from the LLM call, adding signal at each layer (LLM → job → request), then tie everything together in Grafana. Every piece of instrumentation added is immediately visible in a dashboard.

---

## Current State (Gaps)

| Area | What exists | What's missing |
|------|-------------|----------------|
| Tracing | `llm.chat` span with model, message count, response length | Token counts, job span, trace ID in logs |
| Metrics | `llm_request_duration_seconds` histogram (model, status) | Token counters, job duration, error rates, throughput |
| Logs | Fluent Bit ships Docker stdout to Loki | Structured JSON format, trace ID correlation |
| Grafana | Stack running, no provisioned datasources or dashboards | Everything |
| LLM response | Content parsed and returned | `usage.prompt_tokens`, `completion_tokens`, `total_tokens` discarded |
| Traffic | None | Seed data, load generator, scenario script |

---

## Short-Term Work

These four items together make the core demo work end-to-end and give a reader something compelling to look at immediately.

### 1. Token Counting

Parse `usage.prompt_tokens`, `usage.completion_tokens`, and `usage.total_tokens` from the Ollama API response in `LlmClient#make_request`. Surface them in three places:

- **OTEL span attributes**: `llm.prompt_tokens`, `llm.completion_tokens`, `llm.total_tokens` on the existing `llm.chat` span
- **Prometheus counters**: `llm_tokens_total` counter with `model` and `type` (prompt/completion/total) labels
- **Structured log field**: include token counts in the JSON log line for every LLM call

No new files — `LlmClient` grows slightly. The Ollama API returns the `usage` object on every non-streaming response; other OpenAI-compatible endpoints do the same.

### 2. Job Observability

Give `LlmResponseJob#perform` its own OTEL span (`llm_response_job.perform`) with attributes for `chat_id` and `message_id`. Add a Prometheus histogram for job duration (`llm_job_duration_seconds`) with a `status` label (success/error).

This ensures every layer of the stack has its own span — HTTP request → job execution → LLM call — producing a complete distributed trace that a reader can explore in Jaeger.

### 3. Structured Logging with Trace Correlation

Add the `lograge` gem. Configure JSON log output in both development and production environments. Inject `trace_id` and `span_id` from the active OTEL context into every request and job log line.

This lets a reader click a Loki log line in Grafana and jump directly to the matching Jaeger trace — the key moment that shows the three tools working together.

### 4. Grafana Provisioning as Code

Add provisioning configuration under `config/observability/grafana/provisioning/`:

```
config/observability/grafana/provisioning/
  datasources/
    datasources.yml      # Prometheus, Loki, Jaeger
  dashboards/
    dashboards.yml       # provisioning config
    llm-overview.json    # starter dashboard
```

Mount these into the Grafana container in `docker-compose.observability.yml` as read-only volumes. Ship one starter dashboard with panels for: LLM latency (p50/p95/p99), token usage over time, error rate, and job duration. A reader gets a working Grafana the moment they run `docker compose up`.

---

## Long-Term Work

These five items deepen the signal and give the blog post its "wow" moments.

### 5. Tokens-Per-Second Throughput Metric

Calculate `completion_tokens ÷ llm_request_duration_seconds` and expose as a Prometheus gauge (`llm_tokens_per_second`) with a `model` label. Add a panel to the Grafana dashboard. This is the number platform engineers actually care about when evaluating local hardware and model selection.

### 6. Full Grafana Dashboard Suite

Expand beyond the starter dashboard to a suite of four provisioned dashboards:

- **LLM Performance**: latency percentiles, throughput (tokens/sec), token rates (prompt vs completion), error rate
- **Job Pipeline**: queue depth, job duration distribution, success/error rates over time
- **Model Comparison**: side-by-side latency and throughput when switching `LLM_MODEL` env var
- **End-to-End Trace Timeline**: request arrival → job enqueue → LLM call → broadcast, showing where time is spent

All dashboards provisioned as JSON files in `config/observability/grafana/provisioning/dashboards/`.

### 7. Prompt and Response Content Logging

Optionally log the full prompt and LLM response content to Loki, controlled by a `LOG_LLM_CONTENT=true` env var (off by default). When enabled, a reader can search Loki for specific prompts and correlate content with latency and token count. Include a simple redaction helper for patterns matching configurable regex (e.g., email addresses, API keys).

### 8. Prometheus Alerting Rules

Add `config/observability/prometheus/alerts.yml` with two rules:

- **Latency SLO**: p95 LLM request duration > 30s for 2 consecutive minutes
- **Error rate**: LLM error rate > 10% over a 5-minute window

Wire into `docker-compose.observability.yml`. Demonstrates what a real alerting setup looks like without requiring Alertmanager (alerts visible in Prometheus UI).

### 9. Streaming LLM Responses

Switch `LlmClient` from `stream: false` to streaming mode. Update `LlmResponseJob` to broadcast tokens incrementally via Turbo Streams as they arrive. Add two new metrics: `llm_time_to_first_token_seconds` (latency to first chunk) and a per-stream token rate. This is the most complex item and the most impressive demo moment — watching tokens arrive in the browser in real time while the trace fills in alongside.

---

## Traffic Simulation Tools

Without traffic, a reader stares at empty dashboards. These three tools give signal on demand at any stage of following the blog post.

### A. Seed Script (`bin/rails demo:seed`)

A rake task under `lib/tasks/demo.rake` that creates a realistic set of chats and fires a curated batch of messages through the full stack against a live Ollama endpoint. Produces variety in token counts, latencies, and conversation lengths. Purpose: give a reader a populated app with real historical signal before they open Grafana for the first time.

### B. Load Generator (`bin/load-test`)

A script that drives sustained traffic in two modes controlled by a flag:

- `--stub`: mocks the LLM response with a fixed payload and configurable artificial latency (`--latency=2000`). No Ollama required. Deterministic and fast — good for generating metric volume on low-powered hardware or CI.
- `--real`: sends requests through the full stack including Ollama. Produces authentic latency distributions and token counts. Requires a model to be pulled locally.

Both modes accept `--concurrency` and `--duration` flags. Purpose: make rate graphs, percentile histograms, and queue depth panels meaningful rather than flat lines.

### C. Scenario Script (`bin/rails demo:scenario`)

A rake task that runs a scripted sequence of requests designed to trigger specific observable events:

1. A normal response (baseline latency, expected token count)
2. A deliberately slow prompt (long context, produces a latency spike)
3. A request that causes a timeout or error (produces a red bar in the error rate panel)
4. A recovery (normal response after the error)

Purpose: let a reader reproduce the exact dashboard state shown in the blog post screenshots — a spike, a red error bar, a recovery — on demand without waiting for organic traffic.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `app/services/llm_client.rb` | Modify | Token counting, structured log fields |
| `app/jobs/llm_response_job.rb` | Modify | OTEL span, job duration metric |
| `config/initializers/lograge.rb` | Create | JSON logging with trace correlation |
| `Gemfile` | Modify | Add `lograge` gem |
| `config/observability/grafana/provisioning/datasources/datasources.yml` | Create | Grafana data source provisioning |
| `config/observability/grafana/provisioning/dashboards/dashboards.yml` | Create | Grafana dashboard provisioning config |
| `config/observability/grafana/provisioning/dashboards/llm-overview.json` | Create | Starter LLM dashboard |
| `docker-compose.observability.yml` | Modify | Mount Grafana provisioning volumes |
| `lib/tasks/demo.rake` | Create | Seed and scenario rake tasks |
| `bin/load-test` | Create | Load generator script (stub + real modes) |

---

## Success Criteria

**Short-term done when:**
- A reader can `docker compose up` and immediately see a populated Grafana with live data
- Every LLM call produces a trace with token counts, a metric increment, and a correlated log line
- A reader can click a Loki log entry and jump to the matching Jaeger trace

**Long-term done when:**
- All four Grafana dashboards are provisioned and meaningful under load
- Streaming responses visible in the browser with time-to-first-token tracked in Prometheus
- Alerting rules fire correctly under the load generator

**Traffic tools done when:**
- `bin/rails demo:seed` populates the app and produces visible signal in all three tools
- `bin/load-test --stub` and `--real` produce meaningful dashboard activity within 60 seconds of running
- `bin/rails demo:scenario` reproduces the exact dashboard state shown in blog post screenshots
