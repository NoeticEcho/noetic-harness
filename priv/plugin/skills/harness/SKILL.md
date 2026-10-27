---
name: harness
description: Route work through the repository's development harness before doing it, and record it as it is done. It finds which workflow applies, which roles, what to read first, which gates will have to pass, and what earlier work learned. Use at the start of any non-trivial change, when a repository has an .agents directory, or when asked to route, gate or record work.
---

# Working through the harness

A repository that uses the harness keeps a written account of how it is
developed in `.agents/`:
- roles, and the capabilities and skills they carry;
- workflows made of steps, each with the gates it must pass;
- lanes of gates;
- a trust model;
- a project memory.

The engine, `noetic-harness`, reads that directory. It routes work, plans
gates, keeps a run ledger and runs the lanes.

**It plans and records; it does not do the work.** You do the steps. Nothing
here runs your change for you, and nothing here is a substitute for reading
the code.

## First, find out what is here

Two things decide what this skill can do, so check both before anything else:

```bash
command -v noetic-harness    # is the engine installed?
ls .agents                   # does this repository have a harness pack?
```

- **Both.** Follow *The loop*, below.
- **A pack, no engine.** The definitions are plain JSON and Markdown, so read
  them by hand. Start with `.agents/constitution.md`, then the workflow in
  `.agents/workflows/` that fits the work, then the lane in
  `.agents/policies/gates.json` that it names. Tell the user that nothing was
  routed, recorded or gated, because the engine is not installed. Do not
  present your own reading as the engine's answer.
- **No pack.** Say so. `noetic-harness init` writes a starter pack once the
  engine is installed. Until then this plugin's subagents are the part that
  works: each carries its whole prompt, constitution included.

## The loop

```bash
noetic-harness route   --title "<what you are about to do>" --explain
noetic-harness context --title "<the same>" --paths <files you expect to touch>
noetic-harness gates   --lane <lane> --plan --paths <the same files>
```

- `route` names the workflow, the lane, the trust ceiling and the smallest
  team that covers the work. `--explain` prints which signals fired. A route
  you disagree with is a line in `.agents/registry/signals.json`: fix it there,
  and do not work around it silently.
- `context` names what to read before starting.
- `gates --plan` resolves the lane without running it, so you know what will
  have to pass before you write anything.

Then read the contract you are working under:

```bash
noetic-harness workflows --show <workflow id>   # the steps, in order, with their gates
noetic-harness prompt <role id>                 # what that role is told
```

## Record what you did, as you do it

```bash
noetic-harness run --start <workflow id> --title "<the work>"
noetic-harness run --step <step> --outcome done --evidence "<command>: <what it showed>"
noetic-harness run --status
noetic-harness run --finish
```

The ledger records; it does not execute. It refuses:
- a step recorded `done` with no evidence;
- to finish while any step is `failed`, `blocked`, `uncertain` or
  `needs_review`;
- to finish on a lane it did not watch pass. `--finish` runs the lane itself.

## Gates

A lane is a floor, never a ceiling: raise it, never lower it.

**A gate that could not run is `unavailable`, not `passed`**, and a lane
holding one is `partial`. When that happens, say what was attempted, what
failed, why, what is still valid and what is therefore unverified. Do not
report the lane green.

Never edit `.agents/policies/gates.json` to make your work pass. Changing a
gate is a decision with its own review, not a fix.

## What earlier work learned

```bash
noetic-harness memory --query <words>
noetic-harness memory --add --kind lesson --title "<the lesson as a claim>" \
  --body "<what you expected, what was true, how you found out>" --confidence observed
```

The memory is append-only. `--confidence` is not decoration:
- `observed` means you ran it and watched it happen;
- `inferred` means you reasoned to it;
- `reported` means something told you.

## Delegating

This plugin ships a subagent for each role in the starter pack's nucleus.
Each carries its whole standing prompt, constitution included, so it works
with or without the engine.

A repository's own pack may define more roles, or different ones. Once the
engine is installed, `noetic-harness prompt <id>` composes any of them, and
`noetic-harness sync` writes the repository's own subagents into
`.claude/agents/`.

The roles are a competency library, not a process list. A task that seems to
need eight of them has been described badly.
