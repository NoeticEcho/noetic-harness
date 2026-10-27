# Source of Truth

One subsystem owns each kind of state. Nothing else may become a second
authority for it. When two systems must agree, the synchronisation is explicit,
one-directional and traceable — never a side effect.

| State | Owner | Everything else |
|---|---|---|
| Work | Beads: the coordinator's one embedded database, `.beads/embeddeddolt` in the main checkout. Its export, `.beads/issues.jsonl` and `.beads/memories.jsonl` on develop, committed at every landing, is the copy off this machine | A task list in a prompt, a markdown TODO, a second tracker, or a bead written by a cloud worker is a defect. |
| Code | Git | The working tree is a draft until committed. |
| World, content and corpus semantics | PostgreSQL via Ash; the canon in git | TypeDB and Qdrant hold read models, rebuilt from it. |
| An avatar's character and meaning: semantic and autobiographical memory, DNA history, the relations between memories | TypeDB | Postgres holds pointers and the current DNA snapshot; Qdrant indexes; ETS holds hot projections. |
| An avatar's working memory | The avatar core's process state | Lost on restart by design; checkpointed through the memory gate. |
| Operational state | PostgreSQL via Ash | Not a place to park semantics. |
| Raw & generated artifacts | R2 / object storage | Binary blobs do not live in Git. |
| Similarity retrieval | Qdrant | A retrieval accelerator. Never cite it as evidence of a fact. |
| Running application | Tidewave against `mix phx.server` | Reasoning about the running system is not observing it. |
| Visual runtime | Babylon.js client | A screenshot is evidence; a compile is not. |
| Asset workshop | Blender | Offline. Its output enters the repo only as a validated GLB. |
| Development knowledge | `.agents/memory/` + `bd remember` | See `memory.md`. |
| Corpus knowledge | `docs/kb/` → Catalog | Retired, never deleted. |
| Harness telemetry (read model) | Aiven, exported one way from the workstation | Rebuilt from git, never restored and never cited as an authority. The holdout is never exported. |

## The harness's own state

| Harness state | Owner |
|---|---|
| Role definitions | `.agents/registry/agents.json` (+ `overrides/`, `roles/`) |
| Workflow definitions | `.agents/workflows/*.json` |
| Gate definitions | `.agents/policies/gates.json` |
| Generated client adapters | `.claude/agents/`, `.agents/prompts/` — derived, never hand-edited |

A generated file carries a `GENERATED` banner naming the command that produced
it. Editing one is a defect: the next `mix harness.sync` silently reverts it.
Change the canonical source instead.
