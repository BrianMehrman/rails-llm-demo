# Sprint 2: Log Correlation and Grafana Dashboards

**Goal:** Log lines carry trace IDs so a reader can click a Loki entry in Grafana and jump directly to the matching Jaeger trace. Grafana ships with a pre-built LLM dashboard provisioned via Helm values — no manual setup required after `skaffold dev`.

**Spec:** `docs/specs/2026-05-24-observability-enhancement-design.md` (Short-Term items 3 & 4)

**Dependencies:** Sprint 1 must be complete — the Rails app must be running in Kubernetes, Fluent Bit must be collecting container logs, and token/job metrics must exist for the dashboard panels to have data.

---

## Story 2-1: Structured Logging with Trace Correlation

**As a** platform engineer following the blog post,
**I want** every Rails request and job log line to be structured JSON containing the OTEL trace ID and span ID,
**So that** I can click a Loki log entry in Grafana and jump directly to the matching Jaeger trace.

### Acceptance Criteria

- [ ] `lograge` gem added to `Gemfile`
- [ ] `config/initializers/lograge.rb` created; configures lograge to emit JSON in all environments
- [ ] Every request log line includes: `trace_id`, `span_id`, `method`, `path`, `status`, `duration`, `timestamp`
- [ ] When `OTEL_ENABLED=false`, `trace_id` and `span_id` are omitted gracefully — no errors, no `nil` strings
- [ ] When `OTEL_ENABLED=true`, `trace_id` and `span_id` are W3C hex-encoded values from the active OTEL span
- [ ] `LlmResponseJob` log lines include `trace_id`, `span_id`, `chat_id`, `message_id`, and token counts when available
- [ ] Fluent Bit correctly parses JSON log lines from the Rails container (Fluent Bit parser config updated in `charts/fluent-bit/values.yaml` if needed)
- [ ] In Grafana → Explore → Loki, querying `{app="rails-llm-demo"}` returns structured JSON log entries with `trace_id` visible
- [ ] Clicking a `trace_id` value in Grafana navigates to the matching trace in Jaeger (Grafana derived field configured)
- [ ] `bin/rubocop` passes

### Technical Notes

- Extract trace context:
  ```ruby
  ctx = OpenTelemetry::Trace.current_span.context
  trace_id = ctx.trace_id.unpack1("H*")
  span_id  = ctx.span_id.unpack1("H*")
  ```
- Guard with `ctx.valid?` before extracting — returns false when no active span
- Lograge custom payload:
  ```ruby
  config.lograge.custom_payload do |controller|
    ctx = OpenTelemetry::Trace.current_span.context
    ctx.valid? ? { trace_id: ctx.trace_id.unpack1("H*"), span_id: ctx.span_id.unpack1("H*") } : {}
  end
  ```
- Grafana derived field: in the Loki datasource config (Helm values), add a derived field that matches `trace_id` and links to `http://localhost:16686/trace/${__value.raw}` in Jaeger
- Do not add `OTEL_ENABLED` guards beyond the existing initializer — `ctx.valid?` returning false is sufficient

### Files

- Modify: `Gemfile`
- Create: `config/initializers/lograge.rb`
- Modify: `app/jobs/llm_response_job.rb` (add structured log line with trace context and token counts)
- Modify: `charts/fluent-bit/values.yaml` (JSON parser for Rails logs if not already configured)
- Modify: `charts/loki/values.yaml` (derived field for trace ID → Jaeger link)

---

## Story 2-2: Grafana LLM Dashboard via Helm Provisioning

**As a** platform engineer following the blog post,
**I want** Grafana to start with a pre-built LLM dashboard and all data sources connected,
**So that** `skaffold dev` is the entire setup — no manual Grafana configuration needed.

### Acceptance Criteria

- [ ] Grafana data sources (Prometheus, Loki, Jaeger) provisioned via `charts/kube-prometheus-stack/values.yaml` using Grafana's `additionalDataSources` Helm value
- [ ] Stable datasource UIDs set for each source (`prometheus-uid`, `loki-uid`, `jaeger-uid`) so the dashboard JSON can reference them reliably
- [ ] A starter dashboard JSON file created at `charts/kube-prometheus-stack/dashboards/llm-overview.json` with four panels:
  - LLM request latency: p50, p95, p99 from `llm_request_duration_seconds`
  - Token usage over time: `llm_tokens_total` by type (prompt/completion)
  - LLM error rate: rate of `status="error"` label from `llm_request_duration_seconds`
  - Job duration: p50, p95 from `llm_job_duration_seconds`
- [ ] Dashboard provisioned into Grafana via kube-prometheus-stack's `dashboards` Helm value (ConfigMap-backed provisioning)
- [ ] After `skaffold dev`, opening `http://localhost:3001` shows Grafana with all three data sources connected (green) and the LLM Overview dashboard visible — no manual steps
- [ ] Dashboard is marked `"editable": true` so readers can explore without breaking provisioning
- [ ] `docs/observability.md` updated with instructions for viewing the dashboard

### Technical Notes

- kube-prometheus-stack exposes `grafana.additionalDataSources` for adding Loki and Jaeger alongside the built-in Prometheus source
- Dashboard ConfigMap provisioning: use `grafana.dashboards` and `grafana.dashboardProviders` Helm values — the chart handles the ConfigMap creation and Grafana sidecar
- Build the dashboard interactively in a running Grafana first, export JSON via Dashboard → Share → Export, then paste into the Helm values file
- Jaeger datasource type: `grafana-jaeger-datasource`; URL inside cluster: `http://jaeger-query.default.svc.cluster.local:16686`
- Loki datasource URL inside cluster: `http://loki.default.svc.cluster.local:3100`

### Files

- Modify: `charts/kube-prometheus-stack/values.yaml`
- Create: `charts/kube-prometheus-stack/dashboards/llm-overview.json`
- Modify: `docs/observability.md`

### Dependencies

- Story 2-1 (trace ID in logs enables the Loki → Jaeger derived field link)
- Story 1-3 (token metrics must exist for token usage panel)
- Story 1-4 (job duration metric must exist for job duration panel)
