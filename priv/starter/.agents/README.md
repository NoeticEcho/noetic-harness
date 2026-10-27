# `.agents/`

This directory tells the harness how this repository is developed: which roles
exist, which workflows they follow, which gates a change must pass, and what
earlier work learned. It was written by `harness init` from the starter pack,
and it is yours to change.

| Path | What it holds |
|---|---|
| `constitution.md` | The rules every agent prompt starts with |
| `registry/` | Roles, their domains and capabilities, the router's signals, and `project.json` |
| `workflows/` | The workflows, step by step, each with its gates |
| `policies/` | Gates and lanes, trust levels, tools, models, failure routing, the evaluator fence |
| `schemas/` | What `harness validate` checks the rest against |
| `skills/` | Short guides a role loads before working in its area |
| `templates/` | How an agent's prompt is composed |
| `bin/` | Your project's `format`, `lint`, `build` and `test` commands, which the gates run |

## First steps

1. Write the four executables in `bin/` for your language, or run
   `harness init --with <addon> --force` for one the harness ships. Until then
   the gates that run them report `unavailable`, which is honest: nothing has
   checked those things yet.
2. Edit `registry/project.json`: its context sources point roles at your
   documents and tests.
3. Run `harness validate` after any change here.

A wrong route is a line in `registry/signals.json`. A gate that could not run
is `unavailable`, never `passed`.
