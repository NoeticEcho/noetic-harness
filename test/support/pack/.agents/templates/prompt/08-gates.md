# Quality gates

Lane for this task: **{{lane}}**

{{gate_detail}}

Run them. Report each as `passed`, `failed`, `skipped` or `unavailable`.
`unavailable` is never folded into `passed`, and a lane with an unavailable
blocking gate reports `partial` — the work it guarded is unverified.

Weakening a gate to make work pass — lowering a threshold, deleting an
assertion, adding an exclusion, relaxing a bound, removing
`--warnings-as-errors` — is a change to the gate. It needs its own review and
its own reason, and it is never part of the work the gate judges.
