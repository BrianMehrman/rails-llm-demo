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
