---
name: working-with-the-harness
description: How to use this repository's development harness: route work before starting it, read what it points at, open a run, record each step with evidence, and let run --finish run the gates.
---

# Working with the harness

The harness plans and records; it does not do the work. Use it in this order.

1. **Route.** `harness route --title "<what you are about to do>" --explain`
   names the workflow, the lane of gates the change must pass, and the roles.
   `--explain` shows which signals fired. If the route is wrong, fix the signal
   in `.agents/registry/signals.json` rather than working around it.
2. **Read.** `harness context --title "<the same>"` lists what to read first.
   `harness memory --query <words>` shows what earlier work learned.
3. **Plan the gates.** `harness gates --lane <lane> --plan` resolves the lane
   without running it, so you know what will be asked of the change.
4. **Open a run.** `harness run --start <WF-id> --title "..."`. Record each
   step as you finish it: `harness run --step <id> --outcome done --evidence
   "<the command you ran and what it showed>"`. A step recorded done without
   evidence is refused.
5. **Finish.** `harness run --finish` runs the lane itself and refuses to close
   the run while a required step has no outcome or the lane has not passed.
6. **Write down what you learned.** `harness memory --add --kind lesson
   --title "<the lesson as a claim>" --body "..." --confidence observed`.

A gate that could not run is `unavailable`, and the lane is `partial`. That is
the truth about the change, not a problem to hide.
