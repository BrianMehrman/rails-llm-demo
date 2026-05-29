# Blog Post Prep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the in-cluster LLM config bug, apply small app polish, correct stale documentation, and write a README, getting-started guide, and blog post draft so a platform engineer can run the demo from clone to populated Grafana.

**Architecture:** The app runs entirely in Kubernetes via Skaffold. The Rails pod reads config from a ConfigMap (`envFrom`), migrations run automatically on boot via `bin/docker-entrypoint`, Prometheus scrapes the in-cluster pod, and Fluent Bit collects pod logs. Demo rake tasks must therefore run *in-cluster* (`kubectl exec`) to produce signal that the stack collects; the HTTP-based load generator runs from the host against the port-forwarded app.

**Tech Stack:** Ruby 3.3.8 / Rails 8.1, Helm, Skaffold, Kubernetes, Minitest, OpenTelemetry, Prometheus, Loki, Jaeger, Grafana, Ollama.

**Spec:** `docs/specs/2026-05-25-blog-post-prep-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `charts/rails-app/values.yaml` | Modify | Fix env var name (`LLM_BASE_URL` → `OPENAI_API_BASE`), align model, enable OTEL in-cluster |
| `test/controllers/chats_controller_test.rb` | Modify | Test asserting the app tagline renders |
| `app/views/chats/index.html.erb` | Modify | Add app subtitle |
| `app/assets/stylesheets/application.css` | Modify | Style the subtitle with existing tokens |
| `bin/load-test` | Modify | Pre-flight Ollama reachability check in `--real` mode |
| `lib/tasks/demo.rake` | Modify (optional) | Name the Grafana panel in `demo:seed` output |
| `docs/observability.md` | Modify | Remove stale bare-process / `bin/rails server` references |
| `README.md` | Rewrite | Platform-engineer-facing overview of the in-cluster flow |
| `docs/getting-started.md` | Create | Linear setup path, clone → populated Grafana |
| `docs/blog-post.md` | Create | Blog post draft (hook + architecture sections) |
| `docs/specs/future-multi-instance-ports.md` | Create | Future sprint stub for port configurability |

---

## Task 1: Fix the in-cluster LLM endpoint config bug

The Rails pod gets its env from `charts/rails-app/values.yaml` via `envFrom: configMapRef` (`charts/rails-app/templates/deployment.yaml:24-26`). The app reads `OPENAI_API_BASE` (`app/services/llm_client.rb:30`) but the values file sets a different key, `LLM_BASE_URL`. In-cluster the app therefore ignores the configured endpoint and falls back to `http://localhost:11434/v1` (the pod itself), so LLM calls fail. The model name also disagrees with the rest of the repo, and OTEL is unset so traces never reach Jaeger.

**Files:**
- Modify: `charts/rails-app/values.yaml:15-29`

- [ ] **Step 1: Edit the `env:` block**

Replace the existing `env:` block (lines 15-29) with:

```yaml
env:
  RAILS_ENV: production
  RAILS_LOG_TO_STDOUT: "true"
  RAILS_SERVE_STATIC_FILES: "true"
  SECRET_KEY_BASE: placeholder-for-local-dev-only
  # Kubernetes DNS for the postgres service deployed by the postgres chart
  DATABASE_URL: postgresql://postgres:password@postgres:5432/chatbot_development
  QUEUE_DATABASE_URL: postgresql://postgres:password@postgres:5432/chatbot_development_queue
  CABLE_DATABASE_URL: postgresql://postgres:password@postgres:5432/chatbot_development_cable
  # LLM endpoint — the app reads OPENAI_API_BASE (app/services/llm_client.rb).
  # host.docker.internal reaches Ollama running on the host from inside the cluster.
  OPENAI_API_BASE: http://host.docker.internal:11434/v1
  LLM_MODEL: llama4
  # Observability — enabled in-cluster so traces reach Jaeger out of the box.
  OTEL_ENABLED: "true"
  OTEL_EXPORTER_OTLP_ENDPOINT: http://jaeger-collector.default.svc.cluster.local:4318
  OTEL_SERVICE_NAME: rails-llm-demo
```

- [ ] **Step 2: Render the chart and verify the ConfigMap**

Run:
```bash
helm template rails-app charts/rails-app | grep -E "OPENAI_API_BASE|LLM_BASE_URL|OTEL_ENABLED|LLM_MODEL"
```
Expected output contains:
```
OPENAI_API_BASE: "http://host.docker.internal:11434/v1"
LLM_MODEL: "llama4"
OTEL_ENABLED: "true"
```
And does **not** contain any `LLM_BASE_URL` line.

- [ ] **Step 3: Commit**

```bash
git add charts/rails-app/values.yaml
git commit -m "fix(chart): rails app reads OPENAI_API_BASE, align model, enable OTEL in-cluster"
```

---

## Task 2: Add an app subtitle to the chats index (TDD)

The index page shows only `<h1>Your Chats</h1>` with no indication of what the app is. Add a tagline so a first-time reader gets context.

**Files:**
- Modify: `test/controllers/chats_controller_test.rb`
- Modify: `app/views/chats/index.html.erb`
- Modify: `app/assets/stylesheets/application.css`

- [ ] **Step 1: Write the failing test**

In `test/controllers/chats_controller_test.rb`, add before the final `end`:

```ruby
  test "GET /chats shows the app tagline" do
    get chats_url
    assert_response :success
    assert_select ".page-header__subtitle", text: "Rails LLM observability demo"
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
bin/rails test test/controllers/chats_controller_test.rb -n "/tagline/"
```
Expected: FAIL — `expected at least 1 element matching ".page-header__subtitle"`.

- [ ] **Step 3: Add the subtitle to the view**

In `app/views/chats/index.html.erb`, replace the header block (lines 2-4):

```erb
  <div class="page-header">
    <h1>Your Chats</h1>
  </div>
```

with:

```erb
  <div class="page-header">
    <h1>Your Chats</h1>
    <p class="page-header__subtitle">Rails LLM observability demo</p>
  </div>
```

- [ ] **Step 4: Add a style using existing tokens**

Append to `app/assets/stylesheets/application.css`:

```css
.page-header__subtitle {
  margin: 0.25rem 0 0;
  color: var(--text-muted);
  font-size: 0.9rem;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
bin/rails test test/controllers/chats_controller_test.rb -n "/tagline/"
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add test/controllers/chats_controller_test.rb app/views/chats/index.html.erb app/assets/stylesheets/application.css
git commit -m "feat(ui): add observability-demo tagline to chats index"
```

---

## Task 3: Add an Ollama pre-flight check to `bin/load-test --real`

In `--real` mode the load generator drives sustained traffic that depends on a live LLM. The script talks to Rails over HTTP, so a down LLM surfaces only as silently-failing background jobs — the load test reports "success" while every job errors. Add a pre-flight TCP check so the reader gets a clear message before wasting a run.

**Files:**
- Modify: `bin/load-test`

- [ ] **Step 1: Require `socket`**

In `bin/load-test`, add to the require block (after line 8 `require "optparse"`):

```ruby
require "socket"
```

- [ ] **Step 2: Define the pre-flight check**

In `bin/load-test`, immediately after the mode-validation block (after line 49, the `end` that closes `unless options[:mode]`), add:

```ruby
def check_llm_reachable!
  base = ENV.fetch("OPENAI_API_BASE", "http://localhost:11434/v1")
  uri = URI.parse(base)
  Socket.tcp(uri.host, uri.port, connect_timeout: 3) { }
rescue StandardError
  warn "Cannot reach the LLM endpoint at #{base}."
  warn "--real mode needs a live Ollama (or OpenAI-compatible) endpoint."
  warn "Start it (e.g. `ollama serve`) and pull a model (`ollama pull llama4`), then retry."
  exit 1
end

check_llm_reachable! if options[:mode] == :real
```

- [ ] **Step 3: Verify the check fires before touching Rails**

Run with an unreachable endpoint (no Rails or Ollama required — the check exits first):
```bash
OPENAI_API_BASE=http://127.0.0.1:1 ruby bin/load-test --real --duration 1s
```
Expected: prints the three `Cannot reach…` lines and exits non-zero. Confirm:
```bash
echo $?
```
Expected: `1`.

- [ ] **Step 4: Verify `--stub` mode is unaffected**

Run:
```bash
ruby bin/load-test --help
```
Expected: usage prints and exits 0 (the pre-flight does not run for `--help` or `--stub`).

- [ ] **Step 5: Run rubocop on the script**

Run:
```bash
bin/rubocop bin/load-test
```
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add bin/load-test
git commit -m "feat(load-test): pre-flight LLM reachability check in --real mode"
```

---

## Task 4 (optional): Name the Grafana panel in `demo:seed` output

Small clarity touch. Skip if it does not add value during execution.

**Files:**
- Modify: `lib/tasks/demo.rake:72`

- [ ] **Step 1: Update the closing line**

In `lib/tasks/demo.rake`, replace line 72:

```ruby
    puts "\nSeed complete. Open http://localhost:3001 to see the Grafana dashboard."
```

with:

```ruby
    puts "\nSeed complete. Open Grafana at http://localhost:3001 → LLM Overview dashboard to see the signal."
```

- [ ] **Step 2: Verify rubocop**

Run:
```bash
bin/rubocop lib/tasks/demo.rake
```
Expected: no offenses.

- [ ] **Step 3: Commit**

```bash
git add lib/tasks/demo.rake
git commit -m "chore(demo): point seed output at the LLM Overview dashboard"
```

---

## Task 5: Remove stale bare-process references in `docs/observability.md`

Lines 15-21 tell the reader to set `OTEL_ENABLED=true` in `.env` and "Restart `bin/rails server`," contradicting line 13 (Skaffold deploys the Rails app in-cluster) and Task 1 (OTEL is now on by default in the ConfigMap).

**Files:**
- Modify: `docs/observability.md:5-21`

- [ ] **Step 1: Rewrite the "Start the stack" section**

Replace lines 5-21 (from `## Start the stack` through the line ending `...ServiceMonitor resource in charts/rails-app/templates/service-monitor.yaml.`) with:

```markdown
## Start the stack

The observability stack starts automatically with the rest of the local Kubernetes environment:

```bash
skaffold dev
```

Skaffold deploys all services — Postgres, Redis, the Rails app, and the full observability stack — and sets up port-forwards automatically. The Rails app runs in-cluster with `OTEL_ENABLED=true` set in `charts/rails-app/values.yaml`, so traces flow to Jaeger out of the box. Prometheus scrapes the app's `/metrics` endpoint every 15s via the `ServiceMonitor` resource in `charts/rails-app/templates/service-monitor.yaml`.

To turn tracing off, set `OTEL_ENABLED` to `false` in `charts/rails-app/values.yaml` and re-run `skaffold dev`.
```

- [ ] **Step 2: Verify no other bare-process references remain**

Run:
```bash
grep -n "bin/rails server" docs/observability.md
```
Expected: no matches.

- [ ] **Step 3: Commit**

```bash
git add docs/observability.md
git commit -m "docs(observability): remove stale bare-process instructions"
```

---

## Task 6: Rewrite `README.md` for the in-cluster architecture

The current README describes running `bin/rails server` on the host and `bin/rails db:setup` by hand — neither matches the in-cluster reality. Rewrite around `skaffold dev`.

**Files:**
- Rewrite: `README.md`

- [ ] **Step 1: Replace the entire file**

Write `README.md` with exactly this content:

````markdown
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
````

- [ ] **Step 2: Verify referenced docs exist**

Run:
```bash
ls docs/getting-started.md docs/observability.md docs/architecture.md
```
Expected: `docs/observability.md` and `docs/architecture.md` exist now; `docs/getting-started.md` is created in Task 7. If running tasks in order, this check passes after Task 7 — note the dependency and do not block.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): rewrite around the in-cluster Skaffold flow"
```

---

## Task 7: Create `docs/getting-started.md`

The linear setup path. Links to `docs/observability.md` for panel-level depth rather than duplicating it.

**Files:**
- Create: `docs/getting-started.md`

- [ ] **Step 1: Write the file**

Write `docs/getting-started.md` with exactly this content:

````markdown
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

The stack occupies these fixed ports — if any are already in use, Skaffold's port-forward will fail. Running multiple instances on one machine is not yet supported (see [../docs/specs/future-multi-instance-ports.md](specs/future-multi-instance-ports.md)).

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
````

- [ ] **Step 2: Verify internal links resolve**

Run:
```bash
ls docs/observability.md docs/specs/future-multi-instance-ports.md
```
Expected: both exist (the spec stub is created in Task 9 — if running in order, run that first or accept this link resolves after Task 9).

- [ ] **Step 3: Commit**

```bash
git add docs/getting-started.md
git commit -m "docs: add getting-started guide for the in-cluster demo"
```

---

## Task 8: Create `docs/blog-post.md` (hook + architecture draft)

First draft establishing voice and structure for a platform-engineer audience. Hook and architecture sections are written in full; later sections are outlined.

**Files:**
- Create: `docs/blog-post.md`

- [ ] **Step 1: Write the file**

Write `docs/blog-post.md` with exactly this content:

````markdown
# Observability for a Local LLM, From Request to Trace

*Draft — target audience: platform engineers. Status: hook + architecture complete; later sections outlined.*

## The gap

Running an LLM on your laptop is easy now. `ollama pull`, `ollama serve`, point an app at `localhost:11434`, done. What's not easy is answering the questions you'd ask of any production workload: why is this request slow, where did the tokens go, what happened when the model errored, and how much time was spent waiting in a queue versus generating.

A local model makes those questions *more* interesting, not less. You own the whole stack, so every layer is yours to instrument — and every layer is yours to get wrong. This post wires a small Rails chatbot to a local Ollama endpoint and instruments the full path so that a single message produces a distributed trace, a set of metrics, and a correlated log line, all visible in Grafana without any manual setup.

Everything runs in Kubernetes via Skaffold. That's a deliberate choice: a workload running as a bare process while its observability tooling runs in containers is not a setup anyone ships. Putting the app and the Prometheus/Grafana/Loki/Jaeger stack in the same cluster mirrors how this actually looks in production, and makes the wiring — service discovery, scrape configs, log collection — part of the demo instead of hand-waved away.

## The architecture

The request path has three hops, and each one is a place where time goes and things break:

1. **HTTP request.** `POST /chats/:id/messages` saves the user's message, creates an empty `pending` assistant message, enqueues a background job, and redirects. The browser never blocks on the model.
2. **Background job.** `LlmResponseJob` (SolidQueue, running inside Puma — no separate worker) picks up the message, builds conversation history, and calls the LLM.
3. **LLM call.** `LlmClient` speaks the OpenAI HTTP API directly to Ollama, parses the completion and token usage, and the job broadcasts the result back to the browser over Turbo Streams.

Three hops, three different questions, three different tools:

- **Jaeger (traces)** answers *where did the time go?* The request, the job, and the LLM call each open a span, nested into one trace. You can see queue time separate from generation time at a glance.
- **Prometheus (metrics)** answers *what's the trend?* Request-duration histograms, token counters, and job-duration histograms turn individual events into rates and percentiles.
- **Loki (logs)** answers *what exactly happened on this one?* Structured JSON log lines carry the trace ID, so a log entry in Grafana links straight to its Jaeger trace.

The thing that makes these three tools more than the sum of their parts is correlation. A latency spike in a Prometheus panel is a number; click through to the trace and it's a story; jump to the log line and it's a root cause. The rest of this post builds that path one layer at a time.

## What's next in this draft

- **The LLM layer:** instrumenting `LlmClient` — the `llm.chat` span, token counters, and why `usage` data is worth capturing.
- **The job layer:** giving `LlmResponseJob` its own span and duration metric, and why the job span must wrap the LLM span.
- **The request layer:** structured logging with `lograge` and injecting the trace ID into every log line.
- **Tying it together in Grafana:** the pre-provisioned LLM Overview dashboard and the Loki → Jaeger jump.
- **Try it yourself:** pointer to `docs/getting-started.md`.
````

- [ ] **Step 2: Commit**

```bash
git add docs/blog-post.md
git commit -m "docs: add blog post draft (hook + architecture sections)"
```

---

## Task 9: Create the future-sprint spec stub for multi-instance ports

**Files:**
- Create: `docs/specs/future-multi-instance-ports.md`

- [ ] **Step 1: Write the file**

Write `docs/specs/future-multi-instance-ports.md` with exactly this content:

````markdown
# Future Sprint: Multi-Instance Port Configurability

**Status:** Proposed (not scheduled)
**Origin:** Surfaced during blog-post-prep journey audit (see `2026-05-25-blog-post-prep-design.md`).

## Problem

Every port in the stack is hardcoded:

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

These are defined in `skaffold.yaml` (port-forward block) and the various `charts/*/values.yaml`. A developer who runs another Rails app on 3000, another Grafana on 3001, or a second copy of this stack hits a silent port-forward conflict with no clean override.

## Proposed solution

Make every port configurable via environment variables, with the current values as defaults:

`RAILS_PORT`, `GRAFANA_PORT`, `PROMETHEUS_PORT`, `JAEGER_PORT`, `JAEGER_OTLP_PORT`, `LOKI_PORT`, `DB_PORT`, `REDIS_PORT`.

Affects:
- `skaffold.yaml` — template the `localPort` values from env
- `charts/*/values.yaml` — where service ports are referenced
- `.env.example` — document the new variables
- `README.md` / `docs/getting-started.md` — note how to shift ports

This is purely a configuration-surface change — no behavior changes.

## Why it matters

Platform engineers commonly run several stacks at once. The current design forces manual edits to Helm values and Skaffold config to coexist, which undercuts the "zero-manual-configuration" story the demo is built around.
````

- [ ] **Step 2: Commit**

```bash
git add docs/specs/future-multi-instance-ports.md
git commit -m "docs(spec): add future sprint stub for multi-instance port config"
```

---

## Final verification

- [ ] **Run the full test suite**

```bash
bin/rails test
```
Expected: all pass, including the new tagline test.

- [ ] **Run rubocop**

```bash
bin/rubocop
```
Expected: no offenses.

- [ ] **Confirm no stale bare-process references remain in docs**

```bash
grep -rn "bin/rails server" README.md docs/observability.md docs/getting-started.md
```
Expected: no matches.

- [ ] **Confirm the chart renders the corrected env**

```bash
helm template rails-app charts/rails-app | grep "OPENAI_API_BASE"
```
Expected: one line with `http://host.docker.internal:11434/v1`.

- [ ] **(Manual, requires cluster + Ollama) Smoke-test the happy path**

If a cluster and Ollama are available: `skaffold dev`, open <http://localhost:3000>, send a message, confirm a reply. Then `kubectl exec -it deploy/rails-app -- bin/rails demo:seed` and confirm panels populate in Grafana at <http://localhost:3001>. This is the one step that cannot be verified statically; note it explicitly if you cannot run it.
````
