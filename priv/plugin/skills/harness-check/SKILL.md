---
name: harness-check
description: Check the harness definitions in .agents/ for consistency, and the generated adapters for drift. Invoke as /harness-check.
allowed-tools: Bash(noetic-harness:*), Bash(echo:*)
---

## Definitions

!`noetic-harness validate 2>&1 | tail -30`

## Generated adapters

!`noetic-harness sync --check 2>&1 | tail -20`

---

If the sections above say `noetic-harness` was not found, the engine is not
installed and nothing was checked. Say so, and stop.

Otherwise:

- If the validator found anything, fix the **definition** under `.agents/`,
  never the generated file. The next `noetic-harness sync` reverts a hand edit
  silently, which is the worst way to lose a change.
- If the adapters have drifted, run `noetic-harness sync` and read the diff
  before committing it. Drift after a template change is expected. Drift after
  no change at all means somebody edited a generated file.
