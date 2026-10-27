---
name: harness-route
description: Route the work you are about to do through the harness, and read what it says back. That is the workflow, the roles, the lane, what to read first, and the gates that will have to pass. Invoke as /harness-route followed by a one-line description of the work.
allowed-tools: Bash(noetic-harness:*), Bash(echo:*)
---

You are about to start: **$ARGUMENTS**

## Where it routes

!`noetic-harness route --title "$ARGUMENTS" --explain 2>&1 || echo "[noetic-harness did not answer: it is not installed, or it failed as shown above]"`

## What you should read first

!`noetic-harness context --title "$ARGUMENTS" 2>&1 | head -60`

## What will have to pass

!`noetic-harness gates --lane focused --plan 2>&1 || echo "[noetic-harness did not answer]"`

## What earlier work learned

!`noetic-harness memory --query "$ARGUMENTS" 2>&1 | head -40`

---

**If the sections above say `noetic-harness` did not answer, or was not
found,** the engine is not installed. Say so plainly. Nothing was routed, and
no route, lane or gate list may be made up in its place. The `harness` skill
says what can still be done by hand. Stop here.

Otherwise:

1. If the route is wrong, say so and fix `.agents/registry/signals.json`. A bad
   route is a line of data, not an argument, and working around it silently
   leaves the next session with the same bad route.
2. Read what the context section names that you have not already read.
3. Read the workflow's steps with `noetic-harness workflows --show <id>` and
   follow them in order.
4. Before you report done, run the lane for real, not `--plan`, and report
   `unavailable` gates as unverified, never as passed.
