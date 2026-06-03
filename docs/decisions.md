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

## Parallel Slot Port Management

**Decision:** Each git worktree instance of the stack runs in a numbered "slot". Slot 1 is the default (base ports, no changes needed). Slots 2+ use port-offset assignments resolved and stored in `.env` by `bin/use-slot N`.

**Why:** Every port in the stack was hardcoded. Two concurrent worktrees hit silent port-forward conflicts with no override path. The slot system provides deterministic, conflict-free port allocation without requiring manual edits to any config file.

**Daily workflow:**
1. In a new worktree, run `bin/use-slot N` once (e.g. `bin/use-slot 2`). This resolves available ports, writes them to `.env`, and generates `.skaffold/slot-N.yaml`.
2. Run `bin/dev` to start both Skaffold and the Rails server from the resolved port values.
3. `bin/setup-worktree` runs `bin/use-slot` automatically when creating a worktree interactively.

**Constraints:**
- Slot 1 always uses `skaffold.yaml` directly. No `.skaffold/` file is generated for slot 1.
- `.env` and `.skaffold/` are gitignored and instance-specific. Run `bin/use-slot N` in every new worktree.
- Do not edit port values in `.env` manually without regenerating the slot YAML — the two files must stay in sync. Use `bin/use-slot N --force` to recompute both atomically.
- Chart versions in `bin/use-slot` (the `CHART_VERSIONS` constant) must be kept in sync with `skaffold.yaml` when either is updated.

**Port offset:** `actual_port = base_port + (slot - 1) * 20`. The +20 window accommodates 8 services with 12 ports of buffer between slots. Port availability is checked before assignment; if a candidate is taken, the script nudges to the next free port (up to 10 attempts).

**See also:** `docs/specs/parallel-slot-port-management.md` for the full design rationale.
