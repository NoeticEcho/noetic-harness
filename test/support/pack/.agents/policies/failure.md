# Failure Handling and Routing

Blindly retrying a failed step is how an agent burns a budget and learns
nothing. The workflow reacts to the *kind* of failure.

## Terminal states

An agent run ends in exactly one of `DONE`, `FAILED`, `BLOCKED`, `UNCERTAIN`,
`NEEDS_REVIEW`. The constitution defines them; this file says where each one
goes next.

| State | Routing |
|---|---|
| `DONE` | Next workflow step. Evidence is attached or the step is not done. |
| `FAILED` | Route by failure class below. Retry budget decrements. |
| `BLOCKED` | Emit the blocker as a bead with a `discovered-from` link, escalate to the named holder, stop. Do not work around it. |
| `UNCERTAIN` | Route to a verification role, or to the human if no evidence would settle it. Never promote. |
| `NEEDS_REVIEW` | Route to a reviewer role that did not author the work. |

## Failure classes

The **route id** column is the identifier `.agents/policies/failure.json` carries
and `Noetic.Harness.Conductor` dispatches on; the prose beside it is for a
person. `mix harness.validate` asserts the two columns agree for every row —
before that it checked only the first, and the routes had already drifted in
wording while still meaning the same thing, which is the state just before they
stop meaning the same thing.

| Observed | Route to | Route id | Why |
|---|---|---|---|
| Test failed | regression analyst, then the implementing role | `capability:qa.regression` | The test may be right. Read it before changing it. |
| Compile error in unfamiliar code | domain owner for that subsystem | `domain_owner` | Guessing at an unfamiliar module is how contracts break. |
| Semantic mismatch (graph says something else) | domain architect + knowledge role | `capability:semantic.modeling` | Not a code bug. |
| `typeql-check` failure | TypeDB role with the official skill loaded | `capability:typedb.query` | Never "fix" generated TypeQL by pattern-matching the error. |
| Performance regression | performance role with a benchmark, not an opinion | `capability:qa.performance` |  |
| Licence or rights uncertainty | provenance role; hard stop until resolved | `capability:data.provenance` |  |
| Flake suspected | instrument it; two "flakes" in this repository were a stale build and a real race | `instrument` | "Flaky" is a hypothesis, not a diagnosis. |
| Benchmark gain with no holdout gain | quarantine the candidate | `quarantine` | This is the Goodhart signature. |
| Same workflow fails three times | development-evolution workflow (WF-020) | `workflow:WF-020` | The workflow is the defect. |
| Missing tool or service | report `unavailable`, continue what is still verifiable, name what is not | `report_unavailable` | Never downgrade to a weaker check silently. |

## Retry budget

Default three attempts per step, and an attempt only counts as an attempt if it
changed something. Re-running an identical command against an unchanged tree is
not a retry, it is a stall, and the workflow terminates on detecting one.

On exhaustion the workflow emits a `FAILED` artifact containing every attempt,
its diagnosis and its evidence, files a bead, and stops. The evidence is not
reverted along with the code.
