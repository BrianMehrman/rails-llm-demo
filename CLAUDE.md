# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`rails-llm-demo` is a Rails 8.1 chatbot application that demonstrates real-time AI responses using a local or self-hosted LLM. Users create named chats and exchange messages with an AI assistant; responses are generated asynchronously and streamed back to the browser without a page reload. The app is designed as a companion to an observability blog post — its architecture intentionally shows how an HTTP request, a background job, and an LLM call can be stitched together as a distributed trace.

The primary constraint is simplicity and portability: the app must run entirely on a developer's laptop with no external API keys. It targets any OpenAI-compatible endpoint (Ollama, LM Studio, etc.) and ships with a one-command Docker Compose observability stack (Jaeger, Prometheus, Loki, Grafana, Fluent Bit). Infrastructure for local development runs in Kubernetes via Skaffold; production deploys via Kamal into Docker containers.

The codebase deliberately avoids complexity — no authentication, no multi-tenancy, no caching layer beyond what Rails ships with. The `Post` scaffold is a leftover from app generation and is not part of the core feature.

---

## Tech Stack

**Use:**
- Ruby 3.3.8 / Rails 8.1
- PostgreSQL for all storage (app data, job queue, Action Cable)
- SolidQueue (job processing, runs inside Puma — no separate worker)
- Solid Cable (Action Cable over Postgres — no Redis dependency)
- Turbo / Hotwire for real-time UI updates
- Stimulus for JavaScript behavior (minimal — add controllers to `app/javascript/controllers/`)
- Importmap for JavaScript (no Node, no webpack, no npm)
- Propshaft for assets
- Plain CSS with custom properties (see `app/assets/stylesheets/application.css`)
- Kamal for production deployment
- Skaffold + Helm charts for local Kubernetes infrastructure

**Avoid:**
- Sidekiq or any job backend other than SolidQueue
- Redis (Solid Cable replaces Action Cable's Redis adapter; the Redis gem is present but not required for core features)
- Webpack, esbuild, or any Node-based asset pipeline
- External CSS frameworks (Bootstrap, Tailwind, shadcn) — use the existing CSS custom property system
- SQLite
- Any LLM provider SDK — `LlmClient` speaks the OpenAI HTTP API directly via `net/http`

---

## Architecture

### Repository layout

```
app/
  controllers/        # thin — no business logic
  services/           # LlmClient (only service)
  jobs/               # LlmResponseJob (only job)
  views/chats/        # chat UI partials and pages
  javascript/         # Stimulus controllers + application.js scroll/keyboard behavior
  assets/stylesheets/ # single application.css with CSS custom properties
charts/               # Helm charts for Postgres and Redis (local Kubernetes only)
config/observability/ # Prometheus, Fluent Bit configs for the observability stack
docs/                 # observability.md and specs
test/
  models/ controllers/ jobs/ services/ system/
```

### Request → Job → Broadcast data flow

1. `POST /chats/:chat_id/messages` → `MessagesController#create` saves the user message, immediately creates a `pending` assistant `Message` (empty content), enqueues `LlmResponseJob.perform_later(chat_id, assistant_message_id)`, redirects. The browser never waits for the LLM.
2. `LlmResponseJob#perform` finds the pre-created assistant message, builds history from `status: "complete"` messages only, calls `LlmClient#chat`, updates the message to `status: "complete"` (or `status: "error"`).
3. `Turbo::StreamsChannel.broadcast_replace_to` replaces the pending message DOM node in subscribed browsers. The view renders "Thinking…" for `pending` status; the broadcast swaps in the real content.

### Three-database pattern

All three databases run from one Postgres pod in local Kubernetes:

| Rails role | Database | Purpose |
|---|---|---|
| `primary` | `chatbot_development` | App data |
| `queue` | `chatbot_development_queue` | SolidQueue |
| `cable` | `chatbot_development_cable` | Solid Cable |

### Routing

```ruby
resources :chats do
  resources :messages, only: [:create]
end
root "chats#index"
```

The `posts` resource exists but is scaffolding noise — do not build on it.

---

## Coding Conventions

- Linter is `rubocop-rails-omakase`. Run `bin/rubocop --autocorrect` before committing. The Omakase style requires spaces inside array literals: `[ :foo, :bar ]` not `[:foo, :bar]`.
- Controllers are thin — no LLM calls, no business logic. Service objects go in `app/services/`.
- `Message#status` drives both validation and UI rendering. `content` presence is only validated when `status != "pending"`. Only `complete` messages are sent to the LLM as history.
- `LlmClient` wraps the OpenTelemetry span and Prometheus histogram internally — callers just call `LlmClient.new.chat(messages)`.
- OpenTelemetry is a no-op unless `OTEL_ENABLED=true`. The gems are always loaded but the SDK is only configured in the initializer when the env var is set — do not add OTEL_ENABLED guards elsewhere.
- Prometheus middleware is mounted unconditionally in `application.rb` — `/metrics` is always available.

---

## UI & Design Rules

- **No component library.** All styles are in `app/assets/stylesheets/application.css` using CSS custom properties defined in `:root`.
- **Use existing design tokens** — `--primary`, `--surface`, `--border`, `--text-muted`, `--radius`, etc. Do not introduce hardcoded color values.
- **BEM-style class naming** for new components: `.block`, `.block__element`, `.block--modifier`. Existing patterns: `.message`, `.message--user`, `.message--assistant`, `.btn`, `.btn-primary`, `.btn-danger`.
- **Turbo Streams for updates** — use `broadcast_replace_to` with an existing partial. Do not write inline HTML in jobs or controllers.
- **JavaScript** — add behavior in `app/javascript/application.js` (page-level) or as a Stimulus controller in `app/javascript/controllers/`. Do not add `<script>` tags to views.
- No accessibility framework is in place — use semantic HTML elements and ARIA attributes directly.

---

## Testing & Quality Bar

**Definition of done:** tests written and passing, `bin/rubocop` clean, `bin/brakeman` and `bin/bundler-audit` passing.

**Test patterns:**
- HTTP requests are stubbed with WebMock (`stub_request`) in unit and integration tests. WebMock is disabled for system tests so Selenium can reach the local Rails server.
- Tests create records dynamically — do not add fixtures for `chats` or `messages`.
- The `posts` fixture (`test/fixtures/posts.yml`) exists for the scaffold tests only.
- Tests run in parallel by default (`parallelize(workers: :number_of_processors)`).

**Run local CI** (mirrors GitHub Actions, runs all checks in order):
```bash
bin/ci
```

**Individual checks:**
```bash
bin/rails test                        # all unit + integration tests
bin/rails test test/path/to_test.rb   # single file
bin/rails test test/path/to_test.rb:12  # single test by line
bin/rails test:system                 # system tests (requires Chrome)
bin/rubocop                           # lint
bin/brakeman --no-pager               # static security analysis
bin/bundler-audit                     # gem vulnerability scan
```

---

## Important Commands

```bash
# Local dev — ONE command per worktree (shared deps in k8s + Rails run locally)
bin/dev                               # resolve slot, ensure shared deps up, db:prepare, run Rails

# Parallel worktrees: each worktree runs its own Rails on its own port against
# ONE shared dependency stack (postgres, redis, observability). To start a new
# instance, create a worktree and run bin/dev in it — that's all:
git worktree add ../my-worktree -b my-branch
cd ../my-worktree && bin/dev          # auto-assigns the next slot (3000, 3010, 3020, …) + its own DBs
bin/use-slot --list                   # show worktree -> slot assignments
bin/use-slot --release                # free this worktree's slot (before removing the worktree)
# Design: docs/specs/parallel-worktree-shared-deps-plan.md

# Full in-cluster deploy (also builds + runs rails-app inside Kubernetes)
skaffold dev                          # deploys the whole stack incl. the app; opens :3000

# Database
bin/rails db:setup                    # first-time: create + migrate all databases (bin/dev does this too)
bin/reset-db                          # drop + recreate THIS worktree's databases via SQL

# Assets / JS
bin/importmap pin <package>           # add a JS package via importmap

# Production deploy (Kamal)
bin/kamal deploy
bin/kamal logs                        # tail production logs
bin/kamal console                     # Rails console on production server

# Observability stack
docker compose -f docker-compose.observability.yml up -d
# then set OTEL_ENABLED=true in .env and restart the server
```

---

## File Placement Rules

| What | Where |
|---|---|
| Business logic / service objects | `app/services/` |
| Background jobs | `app/jobs/` |
| Stimulus controllers | `app/javascript/controllers/` |
| CSS | `app/assets/stylesheets/application.css` (single file) |
| Observability config | `config/observability/` |
| Architecture specs and design docs | `docs/specs/` |
| Helm chart values (local Kubernetes) | `charts/postgres/values.yaml`, `charts/redis/values.yaml` |

---

## Files to Avoid Changing Casually

| File | Why |
|---|---|
| `db/schema.rb` | Generated by migrations — never edit directly |
| `db/queue_schema.rb`, `db/cable_schema.rb`, `db/cache_schema.rb` | Managed by SolidQueue / Solid Cable / Solid Cache gems |
| `config/credentials.yml.enc` | Encrypted — edit only via `bin/rails credentials:edit` |
| `config/deploy.yml` | Kamal production config — changes affect live deployments |
| `Gemfile.lock` | Updated by `bundle install` / `bundle update` only |
| `charts/*/templates/` | Helm chart templates are stable — prefer `values.yaml` overrides |

---

## Further Reading

- `docs/architecture.md` — component diagram, request→job→broadcast sequence, data model ER, message status lifecycle
- `docs/patterns.md` — how to add a model, controller action, background job, Turbo broadcast, or observability instrumentation
- `docs/decisions.md` — architectural decisions and what NOT to change (SolidQueue, three-database setup, CSS conventions, Posts scaffold)
- `docs/observability.md` — how to run the Jaeger + Prometheus + Loki + Grafana stack and what's instrumented
- `docs/specs/` — feature specs and design documents
- `.env.example` — all supported environment variables with defaults
