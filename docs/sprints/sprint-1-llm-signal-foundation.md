# Sprint 1: LLM Signal Foundation

**Goal:** Every LLM call produces a complete, correlated signal — a trace with token counts, a metric increment, and a structured log line. The job layer gets its own span and duration metric. By the end of this sprint, the most interesting part of the system (the LLM call) is fully observable.

**Spec:** `docs/specs/2026-05-24-observability-enhancement-design.md` (Short-Term items 1 & 2)

**Dependencies:** None — builds on existing `LlmClient` and `LlmResponseJob` without adding gems.

---

## Story 1-1: Token Counting in LlmClient

**As a** platform engineer following the blog post,
**I want** to see prompt token count, completion token count, and total token count for every LLM call,
**So that** I can understand model efficiency, cost proxy, and throughput from a single trace or metric query.

### Acceptance Criteria

- [ ] `LlmClient#make_request` parses `usage.prompt_tokens`, `usage.completion_tokens`, and `usage.total_tokens` from the API response body
- [ ] If the `usage` key is absent (endpoint does not return it), the code handles the nil gracefully — no exception raised, signal simply omitted
- [ ] The existing `llm.chat` OTEL span gains three new attributes: `llm.prompt_tokens`, `llm.completion_tokens`, `llm.total_tokens`
- [ ] A new Prometheus counter `llm_tokens_total` is registered with labels `model` and `type` (values: `prompt`, `completion`, `total`); it is incremented on every successful LLM call
- [ ] Token counts appear in the structured log line for every LLM call (prerequisite: Story 2-1 adds structured logging; this story adds the fields to the hash passed to the logger)
- [ ] Existing `LlmClient` tests still pass
- [ ] New tests cover: token attributes on span, counter increments, graceful nil handling when `usage` is absent

### Technical Notes

- Token data lives at `response_body.dig("usage", "prompt_tokens")` etc. in the parsed JSON
- The Prometheus counter should follow the existing pattern in `LlmClient` — register at class load time with a rescue for `AlreadyRegisteredError`
- OTEL span attributes are set via `span.set_attribute(key, value)` inside the existing `tracer.in_span` block
- Structured log fields: return a hash `{ prompt_tokens:, completion_tokens:, total_tokens: }` from `make_request` alongside the content, or store on the instance for the `chat` method to log

### Files

- Modify: `app/services/llm_client.rb`
- Modify: `test/services/llm_client_test.rb`

---

## Story 1-2: Job Observability

**As a** platform engineer following the blog post,
**I want** to see `LlmResponseJob` as its own span in the distributed trace with a duration metric,
**So that** I can distinguish time spent in the job queue from time spent in the LLM call, and see the full request → job → LLM chain in a single Jaeger trace.

### Acceptance Criteria

- [ ] `LlmResponseJob#perform` is wrapped in an OTEL span named `llm_response_job.perform`
- [ ] The span carries attributes: `chat.id` and `message.id`
- [ ] The span status is set to `ERROR` if `LlmClient::Error` is raised; `OK` otherwise
- [ ] A new Prometheus histogram `llm_job_duration_seconds` is registered with label `status` (values: `success`, `error`)
- [ ] The histogram is observed with the job's wall-clock duration and the correct status label on every execution
- [ ] Existing `LlmResponseJob` tests still pass
- [ ] New tests cover: span created with correct attributes, histogram observed on success, histogram observed on error

### Technical Notes

- Use `OpenTelemetry.tracer_provider.tracer("llm_response_job")` — consistent with how `LlmClient` gets its tracer
- Measure duration with `Process.clock_gettime(Process::CLOCK_MONOTONIC)` at perform start and end — same pattern as `LlmClient`
- Set span status via `span.status = OpenTelemetry::Trace::Status.error(e.message)` inside the rescue block
- The OTEL span should be the outermost wrapper so the `llm.chat` child span nests inside it in Jaeger

### Files

- Modify: `app/jobs/llm_response_job.rb`
- Modify: `test/jobs/llm_response_job_test.rb`

### Dependencies

- Story 1-1 (token counts flow through the job's LlmClient call)
