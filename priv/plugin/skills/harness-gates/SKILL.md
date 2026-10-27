---
name: harness-gates
description: Run a harness gate lane over the working tree and report the result honestly, including what could not run. Invoke as /harness-gates, optionally followed by a lane from .agents/policies/gates.json, which is focused when none is given.
allowed-tools: Bash(noetic-harness:*), Bash(echo:*), Bash(git status:*)
---

## Changed files

!`git status --porcelain 2>&1 | head -40`

## The lane

!`lane="$ARGUMENTS"; noetic-harness gates --lane "${lane:-focused}" 2>&1 || echo "[noetic-harness did not answer: it is not installed, the lane failed, or it could not run, as shown above]"`

---

If the lane section says `noetic-harness` was not found, the engine is not
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
