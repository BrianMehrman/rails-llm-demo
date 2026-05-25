# Sprint 2: Log Correlation and Grafana Dashboards

**Goal:** Log lines carry trace IDs so a reader can click a Loki entry in Grafana and jump directly to the matching Jaeger trace. Grafana ships with a pre-built LLM dashboard provisioned via Helm values — no manual setup required after `skaffold dev`.

**Spec:** `docs/specs/2026-05-24-observability-enhancement-design.md` (Short-Term items 3 & 4)

**Dependencies:** Sprint 1 must be complete — the Rails app must be running in Kubernetes, Fluent Bit must be collecting container logs, and token/job metrics must exist for the dashboard panels to have data.

---

## Story 2-1a: Lograge Setup (Request Logging)

**As a** platform engineer following the blog post,
**I want** every Rails request log line to be structured JSON containing the OTEL trace ID and span ID,
**So that** logs are machine-readable and carry the context needed to correlate with Jaeger traces.

### Acceptance Criteria

- [ ] `lograge` gem added to `Gemfile`
- [ ] `config/initializers/lograge.rb` created; configures lograge to emit JSON in all environments
- [ ] Every request log line includes: `trace_id`, `span_id`, `method`, `path`, `status`, `duration`, `timestamp`
- [ ] When `OTEL_ENABLED=false`, `trace_id` and `span_id` are omitted gracefully — no errors, no `nil` strings
- [ ] When `OTEL_ENABLED=true`, `trace_id` and `span_id` are W3C hex-encoded values from the active OTEL span
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
- Do not add `OTEL_ENABLED` guards beyond the existing initializer — `ctx.valid?` returning false is sufficient

### Files

- Modify: `Gemfile`
- Create: `config/initializers/lograge.rb`

### Dependencies

- None — runs in Wave 1 alongside infra and instrumentation work

---

## Story 2-1b: Job Logging and Fluent Bit Configuration

**As a** platform engineer following the blog post,
**I want** `LlmResponseJob` log lines to be structured JSON with trace ID and token counts, collected by Fluent Bit and visible in Loki,
**So that** I can click a Loki log entry in Grafana and jump directly to the matching Jaeger trace.

### Acceptance Criteria

- [ ] `LlmResponseJob` emits a structured JSON log line containing: `trace_id`, `span_id`, `chat_id`, `message_id`, and token counts when available
- [ ] When `OTEL_ENABLED=false`, `trace_id` and `span_id` are omitted gracefully
- [ ] Fluent Bit correctly parses JSON log lines from the Rails container (Fluent Bit parser config updated in `charts/fluent-bit/values.yaml`)
- [ ] In Grafana → Explore → Loki, querying `{app="rails-llm-demo"}` returns structured JSON log entries with `trace_id` visible
- [ ] `bin/rubocop` passes

### Technical Notes

- Use the same `ctx.valid?` guard pattern from Story 2-1a to extract trace context inside the job
- Token counts are available on the job via the result returned from `LlmClient#chat` (added in Story 1-3)
- Fluent Bit JSON parser: set `Format json` in the `[PARSER]` section of the Fluent Bit Helm values so structured Rails logs are parsed rather than treated as plain text

### Files

- Modify: `app/jobs/llm_response_job.rb` (add structured log line with trace context and token counts)
- Modify: `charts/fluent-bit/values.yaml` (JSON parser for Rails logs)

### Dependencies

- Story 1-2 (Fluent Bit chart must exist before its values can be extended)
- Story 1-4 (job span must exist so trace context is active inside the job)
- Story 2-1a (lograge provides the trace extraction pattern; Gemfile change must be merged first)

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

- Story 2-1a (lograge provides trace context infrastructure; Gemfile change must be merged first)
- Story 1-2 (kube-prometheus-stack chart must exist before its values can be extended)
- Story 1-3 (token metrics must exist for token usage panel)
- Story 1-4 (job duration metric must exist for job duration panel)

> **Note:** Story 2-1b runs in parallel with this story (Wave 3). The Loki → Jaeger derived field can be configured in this story's Helm values without 2-1b being merged first; full end-to-end verification of the link requires 2-1b to be merged before testing.
