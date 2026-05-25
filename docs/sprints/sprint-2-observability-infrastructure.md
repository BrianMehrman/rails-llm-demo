# Sprint 2: Observability Infrastructure

**Goal:** A reader can run `docker compose up` and immediately land in a working Grafana with provisioned data sources and a live LLM dashboard. Log lines carry trace IDs so Loki entries link directly to Jaeger traces. The three observability tools — traces, metrics, logs — work together as a system for the first time.

**Spec:** `docs/specs/2026-05-24-observability-enhancement-design.md` (Short-Term items 3 & 4)

**Dependencies:** Sprint 1 must be complete — structured log fields (token counts, trace IDs) require the signal that Sprint 1 produces.

---

## Story 2-1: Structured Logging with Trace Correlation

**As a** platform engineer following the blog post,
**I want** every Rails request and job log line to be structured JSON containing the OTEL trace ID and span ID,
**So that** I can click a Loki log entry in Grafana and jump directly to the matching Jaeger trace.

### Acceptance Criteria

- [ ] `lograge` gem added to `Gemfile` (production + development groups)
- [ ] `config/initializers/lograge.rb` created; configures lograge to emit JSON format in all environments
- [ ] Every request log line includes: `trace_id`, `span_id`, `method`, `path`, `status`, `duration`, `timestamp`
- [ ] When `OTEL_ENABLED=false` (default), `trace_id` and `span_id` are omitted gracefully — no errors, no `nil` strings in the log output
- [ ] When `OTEL_ENABLED=true`, `trace_id` and `span_id` are the hex-encoded W3C trace context values from the active OTEL span
- [ ] Job log lines (from `LlmResponseJob`) also include `trace_id` and `span_id` when OTEL is enabled
- [ ] `bin/rubocop` passes with no new offenses
- [ ] Manual verification: run `bin/rails server`, send a message, confirm JSON log line appears in stdout with expected fields

### Technical Notes

- Extract trace context via:
  ```ruby
  ctx = OpenTelemetry::Trace.current_span.context
  trace_id = ctx.trace_id.unpack1("H*")
  span_id  = ctx.span_id.unpack1("H*")
  ```
- Guard with `ctx.valid?` before extracting — returns false when no active span
- Lograge custom payload block:
  ```ruby
  config.lograge.custom_payload do |controller|
    ctx = OpenTelemetry::Trace.current_span.context
    ctx.valid? ? { trace_id: ctx.trace_id.unpack1("H*"), span_id: ctx.span_id.unpack1("H*") } : {}
  end
  ```
- Lograge does not cover job logs by default — add a `LogSubscriber` or use `ActiveSupport::TaggedLogging` with a custom formatter in `LlmResponseJob`
- Do not add OTEL_ENABLED guards beyond the existing initializer — the CLAUDE.md convention is that OTEL is a no-op when disabled, so `current_span.context.valid?` returning false is sufficient

### Files

- Modify: `Gemfile`
- Create: `config/initializers/lograge.rb`
- Modify: `app/jobs/llm_response_job.rb` (add log line with trace context)

---

## Story 2-2: Grafana Provisioning as Code

**As a** platform engineer following the blog post,
**I want** Grafana to start with pre-configured data sources and a working LLM dashboard,
**So that** I don't have to manually configure anything — `docker compose up` is the entire setup.

### Acceptance Criteria

- [ ] `config/observability/grafana/provisioning/datasources/datasources.yml` created with three data sources: Prometheus (default), Loki, Jaeger
- [ ] `config/observability/grafana/provisioning/dashboards/dashboards.yml` created as the provisioning config pointing at the dashboards directory
- [ ] `config/observability/grafana/provisioning/dashboards/llm-overview.json` created with a starter dashboard containing four panels:
  - LLM request latency: p50, p95, p99 from `llm_request_duration_seconds`
  - Token usage over time: `llm_tokens_total` by type (prompt/completion)
  - LLM error rate: rate of `status="error"` from `llm_request_duration_seconds`
  - Job duration: p50, p95 from `llm_job_duration_seconds`
- [ ] `docker-compose.observability.yml` updated to mount the provisioning directory into the Grafana container as a read-only volume
- [ ] `GF_PATHS_PROVISIONING` env var set in the Grafana service to point at the mounted path
- [ ] After `docker compose up`, opening `http://localhost:3001` shows Grafana with all three data sources connected and the LLM Overview dashboard visible — no manual steps required
- [ ] `docs/observability.md` updated to reflect that data sources and dashboards are now pre-configured

### Technical Notes

- Datasource UIDs must be stable strings (not auto-generated) so the dashboard JSON can reference them by UID — use `prometheus-uid`, `loki-uid`, `jaeger-uid`
- Jaeger data source type in Grafana is `grafana-jaeger-datasource`; URL is `http://jaeger:16686`
- Loki data source URL is `http://loki:3100`
- Prometheus data source URL is `http://prometheus:9090`
- Dashboard JSON can be exported from a live Grafana instance and saved to the file — build the panels interactively first, then export
- Set `"editable": true` in the dashboard JSON so readers can modify it without breaking provisioning

### Files

- Create: `config/observability/grafana/provisioning/datasources/datasources.yml`
- Create: `config/observability/grafana/provisioning/dashboards/dashboards.yml`
- Create: `config/observability/grafana/provisioning/dashboards/llm-overview.json`
- Modify: `docker-compose.observability.yml`
- Modify: `docs/observability.md`

### Dependencies

- Story 1-1 (token metrics must exist for the token usage panel to have data)
- Story 1-2 (job duration metric must exist for the job duration panel)
