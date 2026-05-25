# Sprint 3: Traffic Simulation

**Goal:** A reader can generate meaningful signal on demand — seeding historical data, sustaining load for rate graphs, or triggering a scripted sequence that reproduces exact blog post screenshots. Dashboards light up within 60 seconds of running any tool.

**Spec:** `docs/specs/2026-05-24-observability-enhancement-design.md` (Traffic Simulation Tools A, B & C)

**Dependencies:** Sprint 1 and Sprint 2 must be complete — all three tools produce signal that the Grafana dashboards must exist to display. The Rails app must be running in Kubernetes (`skaffold dev`) before any tool is run.

---

## Story 3-1: Seed Script

**As a** reader following the blog post,
**I want** a single command that populates the app with realistic chat history and fires messages through the full LLM stack,
**So that** when I open Grafana for the first time I see real historical signal rather than empty graphs.

### Acceptance Criteria

- [ ] `lib/tasks/demo.rake` created with a `demo:seed` task
- [ ] Task creates at least 5 chats with distinct titles and realistic conversation lengths (2–6 messages each)
- [ ] Each user message is fired through the full stack — creates the message record, calls `LlmResponseJob.perform_now` — so traces, metrics, and Fluent Bit-collected logs are all produced
- [ ] Task is idempotent: running it twice does not error; seed chats are identified by a `[Demo]` title prefix and skipped if already present
- [ ] Task prints progress to stdout: which chat is being seeded, which message is being sent
- [ ] Task completes successfully when the Rails app is running and `OPENAI_API_BASE` points to a live Ollama endpoint with a model pulled
- [ ] OTEL spans are flushed before the task exits (`OpenTelemetry.tracer_provider.force_flush` called at end if OTEL is enabled)
- [ ] `docs/observability.md` updated with instructions for running the seed task
- [ ] `bin/rubocop` passes

### Technical Notes

- Use `LlmResponseJob.perform_now` (not `perform_later`) so the job runs synchronously and spans are flushed before the task exits
- Create message records directly via `chat.messages.create!` then call `LlmResponseJob.perform_now(chat.id, msg.id)` — avoids HTTP overhead and keeps the task self-contained
- Idempotency check: `Chat.where("title LIKE '[Demo]%'").exists?` before creating
- Guard the force_flush call: `OpenTelemetry.tracer_provider.force_flush if ENV["OTEL_ENABLED"] == "true"`

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
- [ ] `--stub` mode: starts a minimal WEBrick server on a local port that returns a valid OpenAI-compatible completion response after sleeping for `--latency` ms; sets `OPENAI_API_BASE` to point at this stub; sends POST requests to the Rails app at `http://localhost:3000`
- [ ] `--real` mode: sends requests through the full stack including a live Ollama endpoint
- [ ] Both modes accept `--concurrency N` (default: 3) and `--duration Ns` (default: 60s) flags
- [ ] `--stub` mode accepts `--latency MS` (default: 500) to set artificial response delay
- [ ] Script creates one chat at startup and reuses its ID for all requests
- [ ] Script prints a live counter during execution (requests sent, errors seen)
- [ ] Script prints a summary on exit: total requests, success count, error count, p50/p95 latency
- [ ] Script exits cleanly on Ctrl-C and prints the partial summary
- [ ] Uses only Ruby stdlib — no external gems
- [ ] `bin/rubocop` passes on the script

### Technical Notes

- Stub server: run WEBrick in a background thread before spawning request threads; serve a single route `POST /v1/chat/completions` that sleeps then returns:
  ```json
  {"choices":[{"message":{"content":"stub response"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
  ```
- Concurrency: use `Thread` with a shared counter protected by `Mutex`; a shared `stop` flag set on Ctrl-C (`Signal.trap("INT")`)
- The Rails server must already be running (`skaffold dev` with port-forward to `localhost:3000`)
- Latency tracking: record `Process.clock_gettime` before and after each request; store durations in a thread-safe array for p50/p95 calculation at exit

### Files

- Create: `bin/load-test`

---

## Story 3-3: Scenario Script

**As a** reader following the blog post,
**I want** a script that triggers a specific sequence of observable events — normal, slow, error, recovery —
**So that** I can reproduce the exact dashboard state shown in the blog post screenshots on demand.

### Acceptance Criteria

- [ ] `demo:scenario` rake task added to `lib/tasks/demo.rake`
- [ ] Task runs exactly four requests in sequence, printing the step name and what signal to expect before each:
  1. **Normal** — short prompt, baseline latency, green in error rate panel
  2. **Slow** — long context prompt (200+ word public domain text), produces a latency spike visible in p95 panel
  3. **Error** — `OPENAI_API_BASE` temporarily overridden to an unreachable host, produces a connection refused error, red bar in error rate panel
  4. **Recovery** — short prompt back to normal endpoint, latency returns to baseline
- [ ] `OpenTelemetry.tracer_provider.force_flush` called between each step so each trace lands in Jaeger before the next starts
- [ ] After all four steps, task prints: `"Scenario complete. Check the LLM Overview dashboard in Grafana at http://localhost:3001"`
- [ ] Task works against a live Ollama endpoint for steps 1, 2, 4; step 3 is always synthetic
- [ ] `bin/rubocop` passes

### Technical Notes

- For the error step: temporarily set `ENV["OPENAI_API_BASE"] = "http://localhost:19998"` (nothing listening) before calling `LlmResponseJob.perform_now`, then restore it afterward
- For the slow step: use a long context string as the user message content — a paragraph of Lorem Ipsum or similar public domain text pushes token count high enough to produce authentic latency difference even on fast hardware
- `perform_now` is required for all steps — synchronous execution ensures spans are flushed in order
- Create a dedicated chat for the scenario (`Chat.create!(title: "[Scenario] #{Time.current}")`) so results are isolated from seed data

### Files

- Modify: `lib/tasks/demo.rake` (add `demo:scenario` alongside `demo:seed`)
- Modify: `docs/observability.md`

### Dependencies

- Story 3-1 (`lib/tasks/demo.rake` file created there; this story extends it)
