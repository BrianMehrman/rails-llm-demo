# rails-llm-demo

A Rails 8.1 chatbot app with real-time AI responses, backed by SolidQueue, Solid Cable, and an optional OpenTelemetry observability stack.

## Requirements

- Ruby 3.3.8
- Docker Desktop with Kubernetes enabled
- `kubectl` and `skaffold` CLI tools
- [Ollama](https://ollama.com) (or any OpenAI-compatible LLM endpoint)

## How it works

User messages are saved to Postgres. A SolidQueue job calls the LLM and streams the response back to the browser via Solid Cable (ActionCable over Postgres). SolidQueue workers run inside Puma automatically — no separate worker process needed.

## Databases

Three Postgres databases run from a single Kubernetes pod:

| Database | Purpose |
|---|---|
| `chatbot_development` | App data — chats and messages |
| `chatbot_development_queue` | SolidQueue job storage |
| `chatbot_development_cable` | Solid Cable message bus |

`bin/rails db:setup` creates and migrates all three.

## LLM setup

The app calls any OpenAI-compatible endpoint. [Ollama](https://ollama.com) is the easiest local option:

```bash
brew install ollama
ollama pull llama4
ollama serve          # starts on localhost:11434 by default
```

## Environment variables

Copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

`.env` is gitignored. The defaults work out of the box for the Kubernetes setup.

| Variable | Default | Purpose |
|---|---|---|
| `DB_HOST` | `localhost` | Postgres host |
| `DB_PORT` | `30432` | Kubernetes NodePort for Postgres |
| `REDIS_URL` | `redis://localhost:6379` | Redis URL |
| `OPENAI_API_BASE` | `http://localhost:11434/v1` | LLM endpoint |
| `LLM_MODEL` | `llama4` | Model name passed to the LLM |
| `OTEL_ENABLED` | `false` | Set `true` to enable tracing |

## First-time setup

```bash
bundle install
cp .env.example .env
skaffold dev --port-forward   # terminal 1 — starts Postgres + Redis pods
bin/rails db:setup            # creates all three databases and loads schemas
```

## Daily start

```bash
skaffold dev --port-forward   # terminal 1
bin/rails server              # terminal 2 — http://localhost:3000
```

## Reset the database

Run this if Postgres fails with `initdb: error: directory is not empty` or you want a clean slate:

```bash
bin/reset-db
```

This removes the Kubernetes hostPath volume, restarts the Postgres pod, and runs `db:reset`.

## Running tests

```bash
bin/rails test
```

## Observability

See [docs/observability.md](docs/observability.md) for the full Jaeger + Prometheus + Loki + Grafana setup.

## Scripts

| Script | Purpose |
|---|---|
| `bin/setup` | Install deps, prepare all databases, start server |
| `bin/reset-db` | Clear hostPath data, restart Postgres pod, run `db:reset` |
