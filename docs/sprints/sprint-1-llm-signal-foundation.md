# Sprint 1: Kubernetes Foundation + LLM Signal

**Goal:** The Rails app runs in Kubernetes alongside Postgres and Redis. The full observability stack (Prometheus, Grafana, Loki, Jaeger, Fluent Bit) runs as Helm-managed workloads in the same cluster. Docker Compose is removed. Every LLM call produces a complete signal — a trace with token counts, a Prometheus metric, and a container log collected by Fluent Bit.

**Spec:** `docs/specs/2026-05-24-observability-enhancement-design.md`

**Dependencies:** None — this sprint establishes the foundation everything else builds on.

---

## Story 1-1: Dockerize the Rails App and Add to Skaffold

**As a** platform engineer following the blog post,
**I want** the Rails app to run as a container in the local Kubernetes cluster managed by Skaffold,
**So that** the entire stack — app, databases, and observability tools — runs in one place using the same orchestration layer.

### Acceptance Criteria

- [ ] `Dockerfile` created at the project root, producing a working Rails 8.1 image
- [ ] Image runs `bin/rails server` as the default command on port 3000
- [ ] SolidQueue runs inside Puma (no separate worker container needed — this is already the app's design)
- [ ] All three database connections (primary, queue, cable) work from inside the container using Kubernetes service DNS names (e.g., `postgres.default.svc.cluster.local`)
- [ ] `DATABASE_URL`, `QUEUE_DATABASE_URL`, `CABLE_DATABASE_URL` accepted as env vars and override the default `database.yml` values
- [ ] A new Helm chart `charts/rails-app/` added with a Deployment, Service, and ConfigMap for environment variables
- [ ] `skaffold.yaml` updated to build the Docker image and deploy the `rails-app` chart
- [ ] Skaffold port-forwards the Rails service to `localhost:3000`
- [ ] `bin/rails db:setup` (or equivalent migration job) runs successfully against the in-cluster Postgres
- [ ] `skaffold dev` brings up the full app and it responds at `http://localhost:3000`
- [ ] `bin/rubocop` passes on any new Ruby files

### Technical Notes

- `bin/rails generate dockerfile` produces a starting point — review and tune for this app (no Node, no asset compilation at runtime, three DB connections)
- Set `RAILS_ENV=production` in the container but provide `SECRET_KEY_BASE` via env var (a placeholder value is fine for local dev)
- `database.yml` needs `url:` keys added to each database role so Kubernetes secrets can be passed as a single connection string. Add `url: <%= ENV["DATABASE_URL"] %>` to `primary`, `url: <%= ENV["QUEUE_DATABASE_URL"] %>` to `queue`, and `url: <%= ENV["CABLE_DATABASE_URL"] %>` to `cable`. When the env var is nil Rails ignores the key and falls back to the individual host/port/user/password settings — fully backward-compatible with local dev.
- The Helm chart should use `imagePullPolicy: Never` for local development so Skaffold can inject the locally-built image
- Keep the chart minimal: Deployment + ClusterIP Service + basic liveness probe on `GET /up`

### Files

- Create: `Dockerfile`
- Create: `charts/rails-app/Chart.yaml`
- Create: `charts/rails-app/values.yaml`
- Create: `charts/rails-app/templates/deployment.yaml`
- Create: `charts/rails-app/templates/service.yaml`
- Create: `charts/rails-app/templates/configmap.yaml`
- Modify: `skaffold.yaml`
- Modify: `config/database.yml` (if env var overrides not already present)

---

## Story 1-2: Migrate Observability Stack to Kubernetes and Remove Docker Compose

**As a** platform engineer following the blog post,
**I want** the full observability stack to run as Helm-managed workloads in the same Kubernetes cluster as the app,
**So that** the setup is internally consistent and mirrors how observability tooling is actually deployed in production clusters.

### Acceptance Criteria

- [ ] `kube-prometheus-stack` Helm chart added to `skaffold.yaml` — deploys Prometheus and Grafana into the cluster
- [ ] Grafana accessible at `http://localhost:3001` via Skaffold port-forward
- [ ] Prometheus accessible at `http://localhost:9090` via Skaffold port-forward
- [ ] `grafana/loki` Helm chart added — Loki accessible at `http://localhost:3100` via Skaffold port-forward
- [ ] `jaegertracing/jaeger` Helm chart added — Jaeger UI accessible at `http://localhost:16686`, OTLP HTTP receiver at `localhost:4318`
- [ ] Fluent Bit deployed as a DaemonSet via the `fluent/fluent-bit` Helm chart; configured to collect container logs from all pods in the cluster and forward to Loki
- [ ] Rails app container logs appear in Loki (verifiable via Grafana → Explore → Loki query for `{app="rails-llm-demo"}`)
- [ ] Prometheus scrapes the Rails `/metrics` endpoint (verifiable via Prometheus → Targets)
- [ ] OTEL traces from the Rails app reach Jaeger (verifiable via Jaeger UI with `OTEL_ENABLED=true`)
- [ ] `docker-compose.observability.yml` removed from the repository
- [ ] `config/observability/fluent-bit.conf` and `config/observability/parsers.conf` removed (replaced by Helm values)
- [ ] `config/observability/prometheus.yml` removed (replaced by kube-prometheus-stack ServiceMonitor or scrape config)
- [ ] `docs/observability.md` updated to replace all Docker Compose instructions with Skaffold equivalents
- [ ] `.env.example` updated — remove `RAILS_METRICS_TARGET` (no longer needed)

### Technical Notes

- Use Helm chart versions pinned in `skaffold.yaml` for reproducibility
- kube-prometheus-stack values to configure: disable components not needed (Alertmanager can stay for future use), set Grafana admin password, enable ServiceMonitor CRD
- Prometheus scraping the Rails app: add a `ServiceMonitor` resource in `charts/rails-app/templates/` that selects the Rails service — this is the kube-prometheus-stack native approach
- Fluent Bit DaemonSet needs RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding) to read node logs — the official Helm chart handles this automatically
- Fluent Bit Loki output plugin config via Helm values: set `host: loki`, `port: 3100`, `labels: app=rails-llm-demo`
- Jaeger OTLP endpoint inside cluster: `http://jaeger-collector.default.svc.cluster.local:4318` — set as `OTEL_EXPORTER_OTLP_ENDPOINT` in the Rails app ConfigMap
- Store Helm chart values overrides in `charts/<tool>/values.yaml` files for clarity

### Files

- Modify: `skaffold.yaml`
- Create: `charts/kube-prometheus-stack/values.yaml`
- Create: `charts/loki/values.yaml`
- Create: `charts/jaeger/values.yaml`
- Create: `charts/fluent-bit/values.yaml`
- Create: `charts/rails-app/templates/service-monitor.yaml`
- Remove: `docker-compose.observability.yml`
- Remove: `config/observability/fluent-bit.conf`
- Remove: `config/observability/parsers.conf`
- Remove: `config/observability/prometheus.yml`
- Modify: `docs/observability.md`
- Modify: `.env.example`

### Dependencies

- Story 1-1 (Rails app must be running in Kubernetes before Prometheus can scrape it or Fluent Bit can collect its logs)

---

## Story 1-3: Token Counting in LlmClient

**As a** platform engineer following the blog post,
**I want** to see prompt token count, completion token count, and total token count for every LLM call,
**So that** I can understand model efficiency and throughput from a single trace or metric query.

### Acceptance Criteria

- [ ] `LlmClient#make_request` parses `usage.prompt_tokens`, `usage.completion_tokens`, and `usage.total_tokens` from the API response body
- [ ] If the `usage` key is absent, the code handles nil gracefully — no exception raised, signal simply omitted
- [ ] The existing `llm.chat` OTEL span gains three new attributes: `llm.prompt_tokens`, `llm.completion_tokens`, `llm.total_tokens`
- [ ] A new Prometheus counter `llm_tokens_total` registered with labels `model` and `type` (values: `prompt`, `completion`, `total`); incremented on every successful LLM call
- [ ] Token counts are returned alongside the response content so callers (and log lines added in Story 2-1) can use them
- [ ] Existing `LlmClient` tests still pass
- [ ] New tests cover: token attributes on span, counter increments, graceful nil handling when `usage` is absent

### Technical Notes

- Token data: `response_body.dig("usage", "prompt_tokens")` etc. in the parsed JSON
- Register the Prometheus counter at class load time with a rescue for `AlreadyRegisteredError` — same pattern as the existing histogram
- Return a result struct or hash from `make_request` containing both `content` and `usage` so the `chat` method can set span attributes and pass usage data up to callers

### Files

- Modify: `app/services/llm_client.rb`
- Modify: `test/services/llm_client_test.rb`

### Dependencies

- Story 1-1 (app running in cluster so signal reaches the in-cluster Prometheus)

---

## Story 1-4: Job Observability

**As a** platform engineer following the blog post,
**I want** to see `LlmResponseJob` as its own span in the distributed trace with a duration metric,
**So that** I can distinguish time spent queued from time spent in the LLM call, and see the full request → job → LLM chain in a single Jaeger trace.

### Acceptance Criteria

- [ ] `LlmResponseJob#perform` is wrapped in an OTEL span named `llm_response_job.perform`
- [ ] The span carries attributes: `chat.id` and `message.id`
- [ ] Span status set to `ERROR` if `LlmClient::Error` is raised; `OK` otherwise
- [ ] A new Prometheus histogram `llm_job_duration_seconds` registered with label `status` (values: `success`, `error`)
- [ ] Histogram observed with wall-clock duration and correct status label on every execution
- [ ] Existing `LlmResponseJob` tests still pass
- [ ] New tests cover: span created with correct attributes, histogram observed on success and on error

### Technical Notes

- Use `OpenTelemetry.tracer_provider.tracer("llm_response_job")` — consistent with `LlmClient`
- Measure duration with `Process.clock_gettime(Process::CLOCK_MONOTONIC)` at perform start/end
- Set span status via `span.status = OpenTelemetry::Trace::Status.error(e.message)` in the rescue block
- The job span should be the outermost wrapper so the `llm.chat` child span nests inside it in Jaeger

### Files

- Modify: `app/jobs/llm_response_job.rb`
- Modify: `test/jobs/llm_response_job_test.rb`

### Dependencies

- Story 1-3 (token counts flow through the job's LlmClient call)
