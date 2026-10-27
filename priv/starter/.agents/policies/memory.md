# Project memory

`.agents/memory/records/` holds what earlier work learned: lessons, decisions,
failed approaches. It is append-only. A record that stops being true is retired
with a date and a reason, not deleted.

Each record says how it is known:

| Confidence | Meaning |
|---|---|
| `observed` | Someone ran it and watched |
| `inferred` | Someone reasoned to it |
| `reported` | Something said so |

A record is never promoted from one to the next without new evidence.

`harness memory --query <words>` finds records; `harness memory --add` writes one.
