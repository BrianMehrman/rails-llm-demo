---
name: blog-post-prep-design
description: Design for polishing the demo app, writing a getting-started guide, updating the README, and drafting the blog post targeting platform engineers
metadata:
  type: project
---

# Blog Post Prep Design

**Date:** 2026-05-25
**Status:** Approved
**Goal:** Polish the demo app for public consumption, write documentation a platform engineer can follow from clone to populated Grafana, and produce a first blog post draft establishing voice and architecture narrative.

---

## Context

All three implementation sprints are complete. The app runs in Kubernetes via Skaffold, produces traces (Jaeger), metrics (Prometheus), and structured logs (Loki/Grafana), and ships rake tasks for seeding data and running a scripted scenario. The next step is making this presentable to a reader who is a platform engineer — comfortable with Kubernetes, Helm, and Prometheus, and wants to see how observability wires together for a local LLM workload.

---

## Approach: Journey-Audit-First

Walk the exact path a platform engineer would follow, record every friction point, fix what's in scope, then write documentation grounded in what actually happens rather than what we expect to happen.

---

## Section 1: The Journey Audit

Eight stops, walked in order. At each stop we check whether a reader can succeed without guessing.

| # | Stop | What we check |
|---|------|---------------|
| 1 | Prerequisites | Are required tools (Skaffold, Helm, Ollama, k3d/kind, a pulled model) stated clearly with versions? |
| 2 | Clone + configure | Is `.env.example` complete and self-explanatory? Any gotchas with secrets or credentials? |
| 3 | `skaffold dev` | Does it start cleanly? Are port-forwards documented? Is failure distinguishable from success? |
| 4 | First app visit | Is `http://localhost:3000` understandable on its own without prior context? |
| 5 | `demo:seed` | Does the task run and produce readable output? Does it guide the reader toward the dashboards? |
| 6 | Grafana first open | Is `http://localhost:3001` immediately useful — datasources green, LLM Overview visible, panels populated? |
| 7 | `demo:scenario` | Is the output clear enough to tell a reader "look at the p95 panel now"? |
| 8 | `bin/load-test` | Does it start without confusion? Is the live counter and final summary understandable? |

**Friction definition:** anything that would cause a reader to stop and google, guess, or give up — unclear error messages, missing output, wrong port in docs, a step that silently fails, rake task output that doesn't point toward the next thing to look at.

---

## Section 2: Polish Scope

### In scope

**Rake task output (`demo:seed`, `demo:scenario`):**
Both tasks print progress but do not guide the reader toward what to look at next. After each meaningful step, output should include a prompt — e.g., `"Now open Grafana: http://localhost:3001 → LLM Overview"`. After the scenario completes, point explicitly to the panel that shows the spike and the error bar.

**Port documentation:**
The stack occupies five common ports. A reader with other Rails apps or observability tools running may hit conflicts silently. The getting-started guide will include a port table and a note that ports are fixed for this version.

| Port | Service |
|------|---------|
| 3000 | Rails app |
| 3001 | Grafana |
| 9090 | Prometheus |
| 16686 | Jaeger UI |
| 3100 | Loki |

**Error message clarity:**
If Ollama is not running or a model is not pulled, rake tasks and the load generator currently surface cryptic connection errors. These paths should detect the failure and print a plain message: `"Cannot reach Ollama at $OPENAI_API_BASE. Is it running and is a model pulled?"`.

**App UI context:**
The chats index (`/chats`) has no explanation of what the app is. A small subtitle or tagline ("Rails LLM observability demo") gives a reader arriving for the first time enough context to orient without adding UI complexity.

### Out of scope

Anything requiring architectural changes: port configurability, multi-tenancy, authentication, streaming responses. These go to future sprints.

### Future sprint placeholder — multi-instance port configurability

**Problem:** All port numbers are hardcoded in `skaffold.yaml` port-forward config, Helm values, and documentation. A developer running multiple copies of the stack (or another Rails app on port 3000) has no clean way to shift ports.

**Proposed sprint:** Make all ports configurable via env vars (`RAILS_PORT`, `GRAFANA_PORT`, `PROMETHEUS_PORT`, `JAEGER_PORT`, `LOKI_PORT`). Affects `skaffold.yaml`, `charts/*/values.yaml`, `.env.example`, and documentation. No behavior change — purely configuration surface.

**Why it matters:** Platform engineers often have several stacks running simultaneously. The current design forces them to manually edit Helm values and Skaffold config, which breaks the "zero-manual-configuration" story the blog post is trying to tell.

---

## Section 3: Documentation Deliverables

### README (`README.md`)

Replaces the default Rails-generated README. Audience: a platform engineer who just cloned the repo and wants to understand what this is and whether it's worth their time.

Contents:
- One-paragraph description of what the app demonstrates
- Prerequisites list with required tool versions
- Quick-start: three commands from clone to running stack
- Port table (see above)
- Links to `docs/getting-started.md` and the published blog post

No tutorial content — the README points outward. It should be readable in under two minutes.

### Getting-started guide (`docs/getting-started.md`)

Step-by-step walkthrough derived from the journey audit. Audience: a reader ready to follow along.

Structure mirrors the eight audit stops:
1. Prerequisites (tools, versions, Ollama model)
2. Clone and configure (`.env.example` walkthrough)
3. Start the stack (`skaffold dev`, port-forward confirmation)
4. Verify the app (`http://localhost:3000`)
5. Seed data (`bin/rails demo:seed` + Grafana callout)
6. Explore Grafana (`http://localhost:3001` — what each panel means)
7. Run the scenario (`bin/rails demo:scenario` + which panels to watch)
8. (Optional) Sustained load (`bin/load-test --stub`)

Each stop has: the command to run, what success looks like, and a "what you can see now" callout pointing to the relevant Grafana panel, Jaeger trace, or Loki query.

Port conflict note appears at Stop 3 with the port table.

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
- All in-scope friction fixed; `bin/ci` green after changes
- `README.md` covers prerequisites, quick-start, and port table; readable in under two minutes
- `docs/getting-started.md` walks a reader from clone to populated Grafana at Stop 6 without gaps
- `docs/blog-post.md` has a complete hook and architecture section; voice is established
- Future sprint note for multi-instance port configurability captured in `docs/specs/`

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `README.md` | Rewrite | Platform-engineer-facing project overview |
| `docs/getting-started.md` | Create | Step-by-step reader journey guide |
| `docs/blog-post.md` | Create | Blog post draft (hook + architecture sections) |
| `lib/tasks/demo.rake` | Modify | Add Grafana/panel callouts to seed and scenario output |
| `app/views/chats/index.html.erb` | Modify | Add app subtitle for reader orientation |
| `bin/load-test` | Modify | Improve Ollama connection error message |
| `docs/specs/future-multi-instance-ports.md` | Create | Future sprint spec stub for port configurability |
