---
name: blog-post-prep-design
description: Design for polishing the demo app, fixing stale docs, writing a getting-started guide, updating the README, and drafting the blog post targeting platform engineers
metadata:
  type: project
---

# Blog Post Prep Design

**Date:** 2026-05-25
**Status:** Approved (revised 2026-05-29 after a codebase review)
**Goal:** Polish the demo app for public consumption, correct documentation that no longer matches the architecture, write documentation a platform engineer can follow from clone to populated Grafana, and produce a first blog post draft establishing voice and architecture narrative.

---

## Context

All three implementation sprints are complete. The app runs in Kubernetes via Skaffold, produces traces (Jaeger), metrics (Prometheus), and structured logs (Loki/Grafana), and ships rake tasks for seeding data and running a scripted scenario. The next step is making this presentable to a reader who is a platform engineer — comfortable with Kubernetes, Helm, and Prometheus, and wants to see how observability wires together for a local LLM workload.

A codebase review on 2026-05-29 found that the existing docs predate Sprint 1: `README.md` and `docs/observability.md` still describe running Rails as a bare host process, even though the app now runs in-cluster. The review also found that the rake-task-output polish the original spec called for is already implemented, and that a new `docs/getting-started.md` would heavily overlap the existing `docs/observability.md`. This revision folds those findings in.

---

## Approach: Journey-Audit-First

Walk the exact path a platform engineer would follow, record every friction point, fix what's in scope, then write documentation grounded in what actually happens rather than what we expect to happen.

---

## Section 1: The Journey Audit

Eight stops, walked in order. At each stop we check whether a reader can succeed without guessing.

| # | Stop | What we check |
|---|------|---------------|
| 1 | Prerequisites | Are required tools (Skaffold, Helm, Ollama, k3d/kind, a pulled model) stated clearly with versions? Is Redis's role explained? |
| 2 | Clone + configure | Is `.env.example` complete and self-explanatory? Any gotchas with secrets or credentials? |
| 3 | `skaffold dev` | Does it start cleanly? Are port-forwards documented? Is failure distinguishable from success? |
| 4 | First app visit | Is `http://localhost:3000` understandable on its own without prior context? |
| 5 | Database state | Does the reader know migrations run automatically in-cluster, or are they told (incorrectly) to run `db:setup` by hand? |
| 6 | `demo:seed` | Does the task run and produce readable output? Does it guide the reader toward the dashboards? |
| 7 | Grafana first open | Is `http://localhost:3001` immediately useful — datasources green, LLM Overview visible, panels populated? |
| 8 | `demo:scenario` / `bin/load-test` | Is the scenario output clear enough to say "look at the p95 panel now"? Does load-test fail gracefully when Ollama is down? |

**Friction definition:** anything that would cause a reader to stop and google, guess, or give up — unclear error messages, missing output, wrong port in docs, a step that silently fails, documentation that contradicts the actual architecture, rake task output that doesn't point toward the next thing to look at.

---

## Section 2: Polish Scope

### A. Documentation correctness (highest priority — newly discovered)

The existing docs predate Sprint 1 and describe an architecture that no longer exists. These are factual errors, not framing issues.

- **`README.md` is stale.** It tells the reader to run `bin/rails server` as a bare host process in a second terminal (`README.md:69-71`) and to run `bin/rails db:setup` from the host (`README.md:60-64`). The real architecture runs Rails *inside* Kubernetes — `skaffold.yaml:26` deploys a `rails-app` Helm release, and `bin/docker-entrypoint` runs `bin/rails db:prepare` automatically on container boot. The README needs a structural rewrite around the in-cluster flow, not a reframing.
- **`docs/observability.md` has the same staleness.** Line 21 instructs the reader to "Restart `bin/rails server`," contradicting line 13, which correctly says Skaffold deploys the Rails app. Fix the bare-process references.
- **Migration story.** Because the entrypoint runs `db:prepare` automatically, the reader should never run `db:setup` by hand in the Kubernetes flow. Both the README and the getting-started guide must state the automatic behavior explicitly so a reader does not get confused at Stop 5.

### B. Rake task output — REDUCED (already largely implemented)

The original spec assumed `demo:seed` and `demo:scenario` did not guide the reader. Review shows they already do:
- `demo:seed` ends with `"Open http://localhost:3001 to see the Grafana dashboard."` (`lib/tasks/demo.rake:72`)
- `demo:scenario` prints each step's expected signal (`lib/tasks/demo.rake:117`) and ends with a dashboard pointer (`:134`).

Remaining work is optional and small: name the specific panel in `demo:seed`'s closing line (e.g. "→ LLM Overview"). If it does not add clear value during implementation, drop it. This is no longer a significant scope item.

### C. Port documentation

The stack occupies several common ports. A reader with other Rails apps or observability tools running may hit conflicts silently. The getting-started guide will include a complete port table and a note that ports are fixed for this version. The table must be exhaustive so a reader can check for conflicts before starting.

| Port | Service |
|------|---------|
| 3000 | Rails app |
| 3001 | Grafana |
| 9090 | Prometheus |
| 16686 | Jaeger UI |
| 4318 | Jaeger OTLP collector (HTTP) |
| 3100 | Loki |
| 5432 | Postgres |
| 6379 | Redis |

### D. Error message clarity

`bin/load-test` exits on argument errors but has no friendly message when Ollama is unreachable in `--real` mode. When a connection to `OPENAI_API_BASE` fails, print a plain message: `"Cannot reach Ollama at $OPENAI_API_BASE. Is it running and is a model pulled?"`. (The rake tasks call `LlmResponseJob.perform_now` directly; the job's existing error handling already surfaces failures, so the load generator is the only place needing a friendlier message.)

### E. App UI context

The chats index (`app/views/chats/index.html.erb`) shows only an `<h1>Your Chats</h1>` with no explanation of what the app is. A small subtitle or tagline ("Rails LLM observability demo") gives a reader arriving for the first time enough context to orient without adding UI complexity.

### F. Redis clarity

Skaffold deploys Redis (`skaffold.yaml:21`) and `.env.example`/`README.md` reference it, but `CLAUDE.md` states Redis is "present but not required for core features" — Solid Cable runs over Postgres. A platform engineer reading the prerequisites will wonder why Redis is there. Add a one-line explanation in the prerequisites (Redis is optional / legacy and not required for the core demo), or note it as deferred cleanup.

### Out of scope

Anything requiring architectural changes: port configurability, multi-tenancy, authentication, streaming responses, removing the Redis dependency. These go to future sprints.

### Future sprint placeholder — multi-instance port configurability

**Problem:** Every port (3000, 3001, 9090, 16686, 4318, 3100, 5432, 6379) is hardcoded in `skaffold.yaml` port-forward config, Helm values, and documentation. A developer running multiple copies of the stack (or another Rails app on port 3000) has no clean way to shift ports.

**Proposed sprint:** Make all ports configurable via env vars (`RAILS_PORT`, `GRAFANA_PORT`, `PROMETHEUS_PORT`, `JAEGER_PORT`, `JAEGER_OTLP_PORT`, `LOKI_PORT`, `DB_PORT`, `REDIS_PORT`). Affects `skaffold.yaml`, `charts/*/values.yaml`, `.env.example`, and documentation. No behavior change — purely configuration surface.

**Why it matters:** Platform engineers often have several stacks running simultaneously. The current design forces them to manually edit Helm values and Skaffold config, which breaks the "zero-manual-configuration" story the blog post is trying to tell.

---

## Section 3: Documentation Deliverables

### Doc responsibility split (deconfliction)

`docs/observability.md` already covers the services/ports table, Grafana panel descriptions, `demo:seed`/`demo:scenario` instructions, and Helm chart versions. A new getting-started guide must not duplicate it. Responsibilities split as:

- **`docs/getting-started.md`** — the *linear setup path*: the ordered sequence of commands from clone to populated Grafana, with "what success looks like" at each stop. It is the on-ramp.
- **`docs/observability.md`** — the *reference*: what's instrumented, what each panel means in depth, Helm chart versions, in-cluster URLs, architecture. It is the deep-dive.

The getting-started guide links to `docs/observability.md` for panel-level detail rather than re-explaining it. `docs/observability.md` is corrected for staleness (Section 2A) but not restructured.

### README (`README.md`)

Structural rewrite around the in-cluster architecture. Audience: a platform engineer who just cloned the repo and wants to understand what this is and whether it's worth their time.

Contents:
- One-paragraph description of what the app demonstrates
- Prerequisites list with required tool versions (including the Redis note from Section 2F)
- Quick-start: the correct in-cluster command sequence (`skaffold dev` brings up everything including Rails; migrations run automatically — no host-side `db:setup`)
- Complete port table (see Section 2C)
- Links to `docs/getting-started.md` and `docs/observability.md`

No tutorial content — the README points outward. It should be readable in under two minutes. Remove the stale bare-process and `db:setup` instructions.

### Getting-started guide (`docs/getting-started.md`)

Step-by-step walkthrough derived from the journey audit. Audience: a reader ready to follow along.

Structure mirrors the audit stops:
1. Prerequisites (tools, versions, Ollama model, Redis note)
2. Clone and configure (`.env.example` walkthrough)
3. Start the stack (`skaffold dev` — brings up everything in-cluster; port-forward confirmation; port table + conflict note)
4. Verify the app (`http://localhost:3000`) — note migrations ran automatically
5. Seed data (`bin/rails demo:seed` + Grafana callout)
6. Explore Grafana (`http://localhost:3001`) — brief, then link to `docs/observability.md` for panel detail
7. Run the scenario (`bin/rails demo:scenario` + which panels to watch)
8. (Optional) Sustained load (`bin/load-test --stub`)

Each stop has: the command to run, what success looks like, and a "what you can see now" callout. The guide stays linear and does not duplicate observability.md's reference material.

### Blog post draft (`docs/blog-post.md`)

First draft targeting platform engineers. Not a finished post — enough to establish voice, structure, and narrative.

Initial draft covers:
- **Hook:** Why local LLM observability matters — the gap between "it works on my laptop" and knowing why it's slow, where tokens go, and what happens when the model errors
- **Architecture overview:** The request → job → LLM → broadcast chain; why each layer needs its own signal; how Jaeger, Prometheus, and Loki each answer a different question

Remaining sections (the three signal layers, Grafana walkthrough, "try it yourself" outro) are outlined but not drafted in this sprint — they follow naturally once the guide is written and screenshots are captured.

Tone: direct, technically precise, no hand-holding. Platform engineers read docs; they don't need motivation.

---

## Section 4: Success Criteria

- Journey audit complete; all friction points documented in the spec or fixed in code
- All stale documentation corrected: README and `docs/observability.md` no longer reference the bare `bin/rails server` process or host-side `db:setup`
- All in-scope friction fixed; `bin/ci` green after changes
- `README.md` describes the in-cluster flow, covers prerequisites (with Redis note), quick-start, and the complete port table; readable in under two minutes
- `docs/getting-started.md` walks a reader from clone to populated Grafana (Stop 7) without gaps and without duplicating `docs/observability.md`
- `docs/blog-post.md` has a complete hook and architecture section; voice is established
- Future sprint note for multi-instance port configurability captured in `docs/specs/`

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `README.md` | Rewrite | Correct stale architecture; platform-engineer-facing overview |
| `docs/observability.md` | Modify | Fix bare-process / `bin/rails server` staleness (`:21`) |
| `docs/getting-started.md` | Create | Linear setup path; links to observability.md for depth |
| `docs/blog-post.md` | Create | Blog post draft (hook + architecture sections) |
| `app/views/chats/index.html.erb` | Modify | Add app subtitle for reader orientation |
| `bin/load-test` | Modify | Friendly Ollama-unreachable error message in `--real` mode |
| `lib/tasks/demo.rake` | Modify (optional) | Name the specific Grafana panel in `demo:seed` output — drop if low value |
| `docs/specs/future-multi-instance-ports.md` | Create | Future sprint spec stub for port configurability |
