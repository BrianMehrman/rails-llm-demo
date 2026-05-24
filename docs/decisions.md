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
