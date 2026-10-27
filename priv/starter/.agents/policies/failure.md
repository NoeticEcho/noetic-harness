# Failures, and where they go

Retrying a failed step unchanged spends the budget and teaches nothing. What
happens next depends on the kind of failure.

## Terminal states

A run ends in exactly one of `DONE`, `FAILED`, `BLOCKED`, `UNCERTAIN` or
`NEEDS_REVIEW`. The constitution defines them; this file says where each goes.

| State | Where it goes |
|---|---|
| `DONE` | The next workflow step. Evidence is attached, or the step is not done. |
| `FAILED` | By failure class, below. The retry budget decrements. |
| `BLOCKED` | Record the blocker where the work is tracked, escalate to whoever holds it, stop. |
| `UNCERTAIN` | A verifying role, or a person if no evidence would settle it. Never promoted. |
| `NEEDS_REVIEW` | A reviewer who did not author the work. |

## Failure classes

`.agents/policies/failure.json` carries the same rows as data. The **route id**
is what the conductor dispatches on, and `harness validate` checks that the two
files agree on every row.

| Observed | Then | Route id | Why |
|---|---|---|---|
| Test failed | the implementing role | `capability:qa.regression` | The test may be right. Read it before changing it. |
| Build error in unfamiliar code |  | `domain_owner` | Guessing at code you do not know is how interfaces break. |
| Performance regression |  | `capability:qa.performance` | Measure against a baseline; an opinion is not a measurement. |
| Licence or rights uncertainty |  | `capability:data.provenance` | Stop until it is resolved. |
| Flake suspected |  | `instrument` | "Flaky" is a hypothesis. Instrument it before calling it one. |
| Benchmark gain with no holdout gain |  | `quarantine` | That is what gaming a metric looks like. |
| Same workflow fails three times |  | `workflow:WF-020` | The workflow is the defect. |
| Missing tool or service |  | `report_unavailable` | Never fall back to a weaker check without saying so. |

## Retry budget

Three attempts per step by default, and an attempt counts only if it changed
something. Running the same command again on an unchanged tree is a stall, not
a retry, and the workflow stops when it sees one.

When the budget is spent the run ends `FAILED` with every attempt, its diagnosis
and its evidence. The evidence is kept even when the code is reverted.
