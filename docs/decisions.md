# Architecture Decisions

Decisions made deliberately. Check here before "improving" something — it may already be intentional.

---

## SolidQueue over Sidekiq

**Decision:** Use SolidQueue for background jobs, not Sidekiq.

**Why:** SolidQueue runs inside Puma — no separate worker process to start or manage. The app is designed to run on a developer's laptop with a single `bin/rails server` command. Sidekiq requires a separate process and Redis, adding operational overhead that contradicts the portability goal.

**What to do instead:** If job throughput becomes a concern, tune SolidQueue's concurrency in `config/queue.yml`. Do not introduce Sidekiq or any other job backend.

---

## Three Databases from One Postgres Pod

**Decision:** Use three separate databases (`primary`, `queue`, `cable`) all running in one Postgres instance.

**Why:** Rails 8 multi-database support is first-class. SolidQueue and Solid Cable each need their own database role for schema isolation — the queue tables and cable tables must not share a schema with the app tables. This is the standard Rails 8 setup, not an accident.

| Rails role | Database | Purpose |
|---|---|---|
| `primary` | `chatbot_development` | App data (chats, messages) |
| `queue` | `chatbot_development_queue` | SolidQueue job tables |
| `cable` | `chatbot_development_cable` | Solid Cable subscription tables |

**What to do instead:** Do not consolidate these into a single database. Do not move queue or cable tables into the primary schema.

---

## Single CSS File with Custom Properties

**Decision:** All styles live in `app/assets/stylesheets/application.css` using CSS custom properties. No CSS framework.

**Why:** The app is a demo — simplicity and portability matter more than scale. The custom property system (`--primary`, `--surface`, `--border`, `--text-muted`, `--radius`, etc.) provides enough design consistency without a framework dependency.

**What to do instead:** Add new styles to `application.css`. Use existing custom properties for colors, spacing, and borders. Use BEM-style class naming (`.block`, `.block__element`, `.block--modifier`). Do not introduce Tailwind, Bootstrap, or hardcoded hex values.

---

## Posts Scaffold Is Noise

**Decision:** The `Post` model, controller, views, and routes are not part of the application. They are scaffolding leftover from `rails new` and have not been removed.

**Why not removed:** Low priority; removal requires care to avoid breaking the scaffold-generated test fixtures.

**What to do instead:** Do not build on the Posts resource. Do not copy patterns from `PostsController` or the Posts views — they are Rails scaffold defaults, not project conventions. The canonical examples for this project are `ChatsController`, `MessagesController`, `LlmResponseJob`, and `LlmClient`.

---

## Parallel Worktrees: Shared Deps + Per-Worktree Local Rails

**Decision:** Multiple git worktrees share ONE dependency stack (postgres, redis,
observability) and each runs only its own local Rails server on a per-worktree port,
isolated by its own slot-suffixed databases. A worktree's "slot" is a small stable
integer assigned first-come from a shared registry. The single command `bin/dev`
resolves the slot, ensures the shared deps are up (starting them once if needed),
prepares this worktree's databases, and runs Rails.

**Why:** Running a full isolated stack per worktree (separate postgres + redis +
observability per namespace) is too heavy for a laptop and wasteful — the deps are
identical across worktrees. Sharing them means only the Rails port and database names
vary per worktree. This supersedes the earlier per-slot-full-stack design (every
service port-offset into its own namespace).

**Daily workflow:**
1. In any worktree, run `bin/dev`. First run assigns a slot, brings up the shared deps
   if they aren't already running, creates this worktree's databases, and starts Rails.
2. Start `bin/dev` in another worktree — it reuses the shared deps and runs its own
   Rails on a different port. `bin/use-slot --list` shows the worktree → slot map.
3. `bin/setup-worktree` assigns a slot automatically when a worktree is created.

**How it works:**
- **Slot registry:** `.git/<common-dir>/rails-llm-slots.json` maps worktree path → slot.
  It lives in the shared git common dir so every worktree sees the same data; it is
  inside `.git`, so it is never committed. Assignment is first-come (lowest free slot);
  `bin/use-slot --release` frees one.
- **Ports:** only Rails varies — slot 1 → `3000`, slot 2 → `3010`, slot 3 → `3020`…
  Shared deps keep fixed localhost ports (postgres `5432`, redis `6379`, grafana `3001`,
  prometheus `9090`).
- **Databases:** same postgres, slot-suffixed names. Slot 1 keeps the original
  `chatbot_development` (+ `_queue`/`_cable`/`_cache`) for backward compatibility; slot N
  gets `chatbot_development_sN…`. Injected via `DATABASE_URL`/`QUEUE_…`/`CABLE_…`/
  `CACHE_DATABASE_URL`, so `config/database.yml` is unchanged.
- **Deps reachability:** `skaffold.deps.yaml` deploys the deps once (`skaffold run`) and
  exposes their services as LoadBalancer, so docker-desktop binds them to `localhost`
  with no `kubectl port-forward` process to babysit.

**Constraints:**
- `skaffold.deps.yaml` is the dev dependency stack (no rails-app — Rails runs locally).
  The full in-cluster deploy (`skaffold.yaml`, incl. rails-app) is a separate path and
  is left unchanged.
- The shared postgres password (`charts/postgres/values.yaml` → `auth.password`) must
  match the DB password used to build connection URLs (`DB_PASSWORD`, default `password`).

**See also:** `docs/specs/parallel-worktree-shared-deps-plan.md` for the full design.
