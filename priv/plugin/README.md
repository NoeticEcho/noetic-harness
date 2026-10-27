# noetic-harness, the Claude Code plugin

A development harness for AI coding agents. A repository that uses it writes
down how it is developed, in an `.agents/` directory:
- roles and the capabilities they carry;
- workflows made of steps, each with the gates it must pass;
- lanes of gates, and a trust model;
- a project memory.

The engine, `noetic-harness`, reads that directory. It routes each piece of
work to a workflow and the smallest team of roles that covers it, plans and
runs the gates a change must pass, and keeps a run ledger that refuses a step
reported done without evidence.

This plugin is how Claude uses the harness. **It does not contain the engine.**

It lives in the engine's repository, under `priv/plugin/`, and is released
with it.

## What is in it

| Part | What it is |
|---|---|
| `skills/harness/` | The method: check for the engine and for `.agents/`, route, read, plan the gates, record each step with evidence, finish, remember |
| `skills/harness-route/` | `/harness-route <work>`: the route, what to read, the gate plan and the memory, at once |
| `skills/harness-gates/` | `/harness-gates [lane]`: run a lane and report it honestly, `partial` included |
| `skills/harness-check/` | `/harness-check`: validate the definitions and look for drift in the generated files |
| `skills/harness-remember/` | `/harness-remember <lesson>`: add a record to the project memory |
| `agents/` | Thirty subagents, one for each role in the starter pack's nucleus: architecture, engineering, QA, security, release, operations, documentation, research, data, governance and evolution |

The subagents are generated from the starter pack that `noetic-harness init`
writes, by `harness plugin` in the engine's repository. Each carries its whole
standing prompt, with the agent constitution first, so it does not depend on
the repository having an `.agents/` directory.

**Skills and subagents, and nothing else.** There are no hooks, no MCP
servers, no executables and no `bin/`. The plugin installs nothing and runs
nothing when it is installed. That is deliberate: the plugin directory's
review holds a plugin that bundles a binary or declares an MCP command, and
either one keeps a plugin off claude.ai and Cowork. The engine stays a
separate install.

## Without the engine

When `noetic-harness` is not on the `PATH`:

- **The subagents work.** They are prompts, and each carries its whole prompt.
  Claude can delegate to the security auditor or the test architect in any
  repository.
- **The skill works as a method, and says what it cannot do.** It checks for
  the engine and for `.agents/` first.
  - Where the repository has a pack, it reads the definitions by hand: the
    constitution, the workflow that fits, and the lane it names.
  - It tells you that nothing was routed, recorded or gated.
  - It never presents its own reading as the engine's answer.
- **The four slash skills say that the engine is missing, and stop.** Each
  one asks the engine a question, and Claude is told not to make up an answer
  in its place.

What each skill answers when `noetic-harness` is missing:

| Skill | Without the engine |
|---|---|
| `harness` | Checks for the engine and for `.agents/`. With a pack, reads its definitions by hand and says that nothing was routed, recorded or gated. Without one, says so and points to the subagents |
| `/harness-route` | Says the engine is not installed and nothing was routed. Makes up no route, lane or gate list |
| `/harness-gates` | Says no gate ran. Does not run the lane's commands itself and call the result a lane |
| `/harness-check` | Says the engine is not installed and nothing was checked |
| `/harness-remember` | Says there is no memory to write to, and gives you the record as text to add later |

## Once `noetic-harness` is installed

The plugin needs one command on the `PATH`, `noetic-harness`, and it calls
these subcommands:

`route`, `context`, `gates`, `workflows`, `prompt`, `run`, `memory`,
`validate`, `sync`, `init`.

With the engine:
- the slash skills answer from the repository's own `.agents/`;
- `noetic-harness init` writes a starter pack into a repository that has none;
- `noetic-harness sync` writes the repository's own subagents into
  `.claude/agents/`, generated from its own roles.

Those repository agents sit beside this plugin's, which stay the starter
pack's.

The engine is built from source today (the repository's README says how). A
single-file `noetic-harness` for Linux and macOS is configured, and not yet
built.

## Where it works

In Claude Code, the CLI and the desktop app, every part loads.

On claude.ai, Claude's documentation says a plugin's subagents are not loaded
(<https://claude.com/docs/plugins/platform-support>, read 2026-09-30). There
the skills are the plugin. The plugin has no top-level `bin/`,
which would block installation there.

## Credentials

The plugin reads no credential. It has no `userConfig`, and no file in it
reads a token, a file in the home directory or a tool's configuration.

The skills run `noetic-harness`, `git status` and `echo`, in the repository
Claude is working in. The engine reads and writes that repository's
`.agents/` directory and runs the gate commands the repository defines. The
plugin sends nothing anywhere.

## Privacy, terms and support

The plugin collects nothing and sends nothing to its publisher: no server,
no telemetry, no account. The pages, in the repository's `docs/`:
[privacy](https://github.com/NoeticEcho/noetic-harness/blob/main/docs/plugin-privacy.md),
[terms](https://github.com/NoeticEcho/noetic-harness/blob/main/docs/plugin-terms.md)
and [support](https://github.com/NoeticEcho/noetic-harness/blob/main/docs/plugin-support.md).

## Licence

Apache-2.0. Copyright NoeticEcho contributors. The licence text is in
`LICENSE`, beside this file.
