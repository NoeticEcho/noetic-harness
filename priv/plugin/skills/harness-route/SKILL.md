---
name: harness-route
description: Route the work you are about to do through the harness, and read what it says back. That is the workflow, the roles, the lane, what to read first, and the gates that will have to pass. Invoke as /harness-route followed by a one-line description of the work.
---

You are about to start: **$ARGUMENTS**

Ask the engine four things, each with the Bash tool, in the repository you
are working in. Pass the description above as **one** argument, quoted for
the shell, so that nothing in it is read as a command.

1. **Where it routes:** `noetic-harness route --title '<the description>' --explain`
2. **What you should read first:** `noetic-harness context --title '<the description>'`
   (the first 60 lines are enough)
3. **What will have to pass:** `noetic-harness gates --lane focused --plan`
4. **What earlier work learned:** `noetic-harness memory --query '<the description>'`
   (the first 40 lines are enough)

**If `noetic-harness` is not installed** (the shell says it was not found),
the engine is not installed. Say so plainly. Nothing was routed, and no route,
lane or gate list may be made up in its place. The `harness` skill says what
can still be done by hand. Stop here.

Otherwise:

1. If the route is wrong, say so and fix `.agents/registry/signals.json`. A bad
   route is a line of data, not an argument, and working around it silently
   leaves the next session with the same bad route.
2. Read what the context names that you have not already read.
3. Read the workflow's steps with `noetic-harness workflows --show <id>` and
   follow them in order.
4. Before you report done, run the lane for real, not `--plan`, and report
   `unavailable` gates as unverified, never as passed.
