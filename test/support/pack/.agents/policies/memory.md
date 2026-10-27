# Project Memory

Memory exists for one purpose: so a future agent does not repeat a mistake this
project has already paid for. It is not a transcript, and it is not a summary of
what happened. A record earns its place by changing what someone would do next.

## Two stores, one rule

| Store | Holds | Read with |
|---|---|---|
| `bd remember` / `bd memories` | Cross-session insights tied to the work graph. The conversational store. | `bd memories <keyword>` |
| `.agents/memory/records/*.json` | Structured, provenance-carrying development knowledge the harness itself routes on: rejected approaches, package rules, TypeQL lessons, benchmark results, gate failures, workflow outcomes. | `mix harness.memory --query <term>` |

The rule: **anything the Context Builder must be able to inject automatically
lives in `.agents/memory/`.** Anything a human or an agent will look up by hand
can live in beads. When in doubt, write it in `.agents/memory/` — it is indexed,
and the beads store is not.

Do not create `MEMORY.md` files. They fragment across accounts and no reader
finds them.

## What a record must carry

Every record is a JSON object validated by `.agents/schemas/memory_record.schema.json`:

```json
{
  "id":         "mem-2026-09-20-typeql-fetch-clause",
  "kind":       "lesson | decision | rejected_approach | failure | benchmark | constraint | package_rule | incident",
  "title":      "one line, stated as the thing to do or avoid",
  "body":       "what was tried, what happened, what it means for the next agent",
  "scope":      ["typedb", "acme_knowledge"],
  "provenance": {
    "source":   "run | human | ci | external",
    "agent":    "core_engineering.typedb",
    "workflow": "WF-002",
    "task":     "an earlier change",
    "artifact": "path or id",
    "commit":   "sha"
  },
  "confidence": "observed | inferred | reported",
  "status":     "current | retired",
  "superseded_by": null,
  "created_at": "2026-09-20T00:00:00Z",
  "version":    1
}
```

`confidence` is not decoration. `observed` means this session watched it happen.
`inferred` means it follows from something observed. `reported` means a
document or a person said so and nothing here checked it. An agent citing a
`reported` record in an argument must say so.

## Append-only

Records are never edited in place except to set `status: "retired"` and
`superseded_by`. A retired record keeps its text: the value of the store is that
you can see what this project used to believe and why it stopped. `status:
current` is the default filter; `--all` shows the retired ones.

An agent may not retire a record it wrote in the same run as the work that
motivated retiring it. That is the evaluator rule from the constitution applied
to memory.

## What not to record

- Anything derivable from the code, the git history or `CLAUDE.md`.
- Anything that only mattered inside one conversation.
- Secrets, credentials, tokens, customer data, or personal data of any kind.
- "We implemented X." The commit says that. Record *why the obvious approach to X
  did not work*.
