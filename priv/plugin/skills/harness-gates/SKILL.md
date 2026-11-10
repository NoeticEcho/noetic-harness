---
name: harness-gates
description: Run a harness gate lane over the working tree and report the result honestly, including what could not run. Invoke as /harness-gates, optionally followed by a lane from .agents/policies/gates.json, which is focused when none is given.
---

The lane asked for: **$ARGUMENTS** (when this is empty, the lane is `focused`).

Run two things with the Bash tool, in the repository you are working in:

1. **Changed files:** `git status --porcelain` (the first 40 lines are enough).
2. **The lane:** `noetic-harness gates --lane <lane>`, with the lane's name
   quoted for the shell. A lane's name is a word from
   `.agents/policies/gates.json`; if what was asked for is not one, say so and
   ask which lane was meant rather than running anything.

If the shell says `noetic-harness` was not found, the engine is not
installed and **no gate ran**. Say exactly that. Do not run the commands in
`.agents/policies/gates.json` yourself and call the result the lane's.

Otherwise report the result as the harness gave it, and do not improve on it:

- **passed**: say so plainly, naming the lane.
- **failed**: the failure is the deliverable. Quote it, find the cause, fix
  the cause rather than the symptom, and run the lane again.
- **partial**: a blocking gate could not run. Say what was attempted, what
  failed, why, what is still valid and what is therefore **unverified**. A
  lane with a hole in it is not a green lane.

Never edit `.agents/policies/gates.json` to make a lane pass. Changing a gate
is a decision with its own review, not a fix.
