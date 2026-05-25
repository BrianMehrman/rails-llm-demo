# Sprint 3: Traffic Simulation

**Goal:** A reader can generate meaningful signal on demand — seeding historical data, sustaining load for rate graphs, or triggering a scripted sequence that reproduces exact blog post screenshots. Dashboards light up within 60 seconds of running any tool.

**Spec:** `docs/specs/2026-05-24-observability-enhancement-design.md` (Traffic Simulation Tools A, B & C)

**Dependencies:** Sprint 1 and Sprint 2 must be complete — all three tools produce signal that the Grafana dashboards must exist to display.

---

## Story 3-1: Seed Script

**As a** reader following the blog post,
**I want** a single command that populates the app with realistic chat history and fires messages through the full LLM stack,
**So that** when I open Grafana for the first time I see real historical signal rather than empty graphs.

### Acceptance Criteria

- [ ] `lib/tasks/demo.rake` created with a `demo:seed` task
- [ ] Task creates at least 5 chats with distinct titles and realistic conversation lengths (2–6 messages each)
- [ ] Task fires each user message through the full stack — `MessagesController` → `LlmResponseJob` → `LlmClient` → real Ollama endpoint — so traces, metrics, and logs are produced
- [ ] Task is idempotent: running it twice does not error; it either skips existing seed data or appends safely
- [ ] Task prints progress to stdout: which chat is being created, which message is being sent
- [ ] Task completes successfully when `OPENAI_API_BASE` points to a live Ollama endpoint with a model pulled
- [ ] `README` or `docs/observability.md` updated with instructions for running the seed task
- [ ] `bin/rubocop` passes

### Technical Notes

- Use `perform_now` (not `perform_later`) in the rake task so the job runs synchronously and the task does not exit before traces are flushed
- Use `Rails.application.routes.url_helpers` for URL generation if needed, or call the service objects directly: create messages via `chat.messages.create!` and call `LlmResponseJob.perform_now(chat.id, msg.id)` directly
- Seed data idempotency: check for existence via a known title prefix (e.g., `"[Demo]"`) before creating
- Flush OTEL spans before exit: call `OpenTelemetry.tracer_provider.force_flush` at the end of the task if OTEL is enabled

### Files

- Create: `lib/tasks/demo.rake`
- Modify: `docs/observability.md`

---

## Story 3-2: Load Generator

**As a** reader following the blog post,
**I want** a script that drives sustained traffic in either stub or real mode,
**So that** rate graphs, percentile histograms, and queue depth panels show meaningful data rather than flat lines.

### Acceptance Criteria

- [ ] `bin/load-test` created as an executable Ruby script
- [ ] `--stub` mode: sends HTTP POST requests to `/chats/:id/messages` with a pre-created chat; the LLM response is mocked at the HTTP level using a local WEBrick stub server or by pointing `OPENAI_API_BASE` at a local stub that returns a fixed payload with configurable delay
- [ ] `--real` mode: sends requests through the full stack including a live Ollama endpoint
- [ ] Both modes accept `--concurrency N` (default: 3) and `--duration Ns` (default: 60s) flags
- [ ] `--stub` mode accepts `--latency MS` to set artificial response delay in milliseconds (default: 500)
- [ ] Script prints a summary on exit: total requests, success count, error count, p50/p95 latency
- [ ] Script exits cleanly on Ctrl-C, printing the partial summary
- [ ] `bin/rubocop` passes on the script

### Technical Notes

- Simplest stub approach: start the Rails app with `OPENAI_API_BASE` pointing to `http://localhost:19999` and run a minimal WEBrick server in a thread that sleeps for `--latency` ms then returns a valid completion response body. No mocking library needed.
- Alternatively, run the app normally and use WebMock — but WebMock does not work across processes. Use a real stub server.
- Concurrency: use Ruby `Thread` with a shared counter protected by a `Mutex`. Keep it stdlib-only — no external gems.
- Create one chat at script startup; reuse its ID for all requests. This keeps the database clean.
- HTTP requests from the script go to `http://localhost:3000` — the Rails server must be running separately.

### Files

- Create: `bin/load-test`

---

## Story 3-3: Scenario Script

**As a** reader following the blog post,
**I want** a script that triggers a specific sequence of observable events (normal → slow → error → recovery),
**So that** I can reproduce the exact dashboard state shown in the blog post screenshots on demand.

### Acceptance Criteria

- [ ] `demo:scenario` rake task added to `lib/tasks/demo.rake`
- [ ] Task runs exactly four requests in sequence:
  1. **Normal**: short prompt, expects a standard latency response
  2. **Slow**: long prompt (200+ tokens of context), expects elevated latency; artificial delay injected via a configurable `SLOW_LLM_LATENCY_MS` env var when using a stub endpoint
  3. **Error**: points `OPENAI_API_BASE` temporarily at an unreachable host to trigger `LlmClient::Error`, producing an error span and error metric
  4. **Recovery**: short prompt back to the normal endpoint, confirming the system recovers cleanly
- [ ] Each step prints to stdout before executing: step number, type, and what signal to expect in Grafana
- [ ] Task works against a live Ollama endpoint for steps 1, 2, 4; step 3 is always synthetic (unreachable host)
- [ ] After all four steps, task prints: "Scenario complete. Check Grafana LLM Overview dashboard."
- [ ] `bin/rubocop` passes

### Technical Notes

- For the error step, temporarily override `ENV["OPENAI_API_BASE"]` to `"http://localhost:19998"` (nothing listening) within the task before calling `LlmResponseJob.perform_now` — this is sufficient to produce a connection refused error
- For the slow step with a real Ollama endpoint, use a very long context prompt (copy of a public domain text excerpt) rather than relying on artificial delay — produces authentic latency signal
- `perform_now` is required for all steps so each job completes and its spans are flushed before the next step begins
- Call `OpenTelemetry.tracer_provider.force_flush` between steps to ensure each trace lands in Jaeger before the next one starts

### Files

- Modify: `lib/tasks/demo.rake` (add `demo:scenario` task alongside `demo:seed`)
- Modify: `docs/observability.md`

### Dependencies

- Story 3-1 (`demo.rake` file created there; this story extends it)
