# noetic-harness

A development harness for AI coding agents.

A repository that uses it writes down how it is developed, in an `.agents/`
directory:
- the roles that do the work, the capabilities they carry and the skills
  those bring;
- workflows made of steps, each naming the gates it must pass;
- lanes of gates, and a trust model that says who may do what;
- a run ledger and a project memory, both append-only.

The engine reads that directory. It routes each piece of work to a workflow
and the smallest team of roles that covers it. It says what to read first,
and plans and runs the gates a change must pass. It keeps a run ledger that
refuses a step reported done without evidence, and refuses to close a run
whose gates it did not watch pass.

It plans and records; it does not do the work. An agent, or a person, does
the steps.

## What is here

| Path | What it is |
|---|---|
| `lib/` | The engine: an Elixir application of mix tasks, with no service to start |
| `priv/starter/` | The starter pack `harness init` writes into a repository: workflows, three lanes of gates, thirty roles, nine skills, the constitution every role's prompt begins with |
| `priv/starter-addons/elixir/` | An add-on for Elixir repositories: a domain, three roles, four skills, and the format, build and test commands the gates call |
| `priv/full/` | The full catalogue, `init --with full`: 184 more roles, with the capabilities, domains, skills and workflows they need, beside the starter's |
| `priv/plugin/` | The Claude Code plugin: five skills, and a subagent for each of the starter pack's roles |

## Install

**The quickest way is the single executable from the
[latest Release](https://github.com/NoeticEcho/noetic-harness/releases/latest).**
It needs no Erlang or Elixir:

```sh
# Linux x86_64; on Apple silicon take noetic-harness-macos-aarch64
curl -fsSLO https://github.com/NoeticEcho/noetic-harness/releases/latest/download/noetic-harness-linux-x86_64
curl -fsSLO https://github.com/NoeticEcho/noetic-harness/releases/latest/download/SHA256SUMS
grep linux-x86_64 SHA256SUMS | sha256sum -c -     # on macOS: shasum -a 256 -c
chmod +x noetic-harness-linux-x86_64
mv noetic-harness-linux-x86_64 ~/.local/bin/noetic-harness
```

Then, in the repository you develop:

```sh
noetic-harness init      # the starter pack into .agents/
noetic-harness sync      # Claude Code's subagents and MCP server, and the
                         # Codex, Gemini and Cursor adapters
```

After `sync`, Claude Code in that repository has the whole harness: the
routing, the gate lanes, the run ledger and the project memory through the
MCP server, and the repository's own roles as subagents. The Claude plugin
(`priv/plugin/`, below) is the part that also works where nothing can be
installed, such as claude.ai and Cowork: the roles and the method, without
the engine.

The executable unpacks itself into `~/.local/share/.burrito/` on its first
run, keyed by version, so a newer release unpacks beside the old one.

### From source

It needs git, and the Erlang/OTP and Elixir versions in `.tool-versions`.
On macOS, `brew install coreutils`
too, for `timeout`, which signed records need. Homebrew installs it as
`gtimeout`; link that one command as `timeout` into a directory on your
`PATH` (for example `ln -s "$(brew --prefix)/bin/gtimeout" ~/.local/bin/timeout`)
rather than putting all of GNU's tools ahead of macOS's own.

```sh
git clone https://github.com/NoeticEcho/noetic-harness
cd noetic-harness
mix deps.get
mix compile
```

### One executable

`noetic-harness` can be built as a single file that needs no Erlang or
Elixir where it runs. Building it needs [Zig](https://ziglang.org) 0.16.0
and `xz`; [Burrito](https://github.com/burrito-elixir/burrito) wraps the
release and the Erlang runtime into one executable.

```sh
MIX_ENV=prod mix deps.get
MIX_ENV=prod BURRITO_TARGET=linux_x86_64 mix release
cp burrito_out/noetic_harness_linux_x86_64 ~/.local/bin/noetic-harness
```

`BURRITO_TARGET=macos_aarch64` builds the one for macOS on Apple silicon,
and with no `BURRITO_TARGET` both are built.

`.github/workflows/release.yml` builds both on every push and runs `init`,
`validate` and `route` with each in a fresh repository. On a tag `v*` it
attaches them to that tag's GitHub Release as `noetic-harness-linux-x86_64`
and `noetic-harness-macos-aarch64`, with a `SHA256SUMS` file. A downloaded
file needs `chmod +x` before it runs.

### From the checkout, with mix

Without the executable, the harness runs as mix tasks inside this checkout,
pointed at the repository you are developing. This script is then the
`noetic-harness` command. Save it as an executable file called
`noetic-harness` in a directory on your `PATH`, and set
`NOETIC_HARNESS_HOME` to the checkout:

```sh
#!/bin/sh
sub=$1
shift
export NOETIC_HARNESS_CALLER_DIR="$PWD"
export NOETIC_HARNESS_ROOT="${NOETIC_HARNESS_ROOT:-$PWD}"
cd "$NOETIC_HARNESS_HOME" && exec mix "harness.$sub" "$@"
```

## Use

In the repository you are developing:

```sh
noetic-harness init                      # write the starter pack into .agents/
noetic-harness init --with elixir        # the same, with the Elixir add-on
noetic-harness init --with full          # the same, with the full catalogue of roles
noetic-harness validate                  # check the definitions
noetic-harness route --title "fix the parser's handling of empty input" --explain
noetic-harness gates --lane fast --plan
noetic-harness run --start WF-002 --title "fix the parser's handling of empty input"
```

`init` never deletes anything, and refuses an existing `.agents/` unless told
`--force`. The gates run `.agents/bin/format`, `lint`, `build` and `test`,
which you write for your language. Until you do, those gates report
`unavailable` and a lane that needs them reports `partial`. That is the truth
about the change, not a failure to hide.

`noetic-harness sync` writes the Claude Code subagents for your repository's
own roles, and instructions for Codex, Gemini and Cursor. The instructions
start `noetic-harness mcp`, the harness as a read-only MCP server, from the
repository's root. `noetic-harness hook <event>` answers a Claude Code hook
(`session_start`, `user_prompt`, `pre_tool` or `session_end`), with the
hook's JSON on stdin.

## The Claude Code plugin

`priv/plugin/` is a Claude Code plugin. It has the `harness` skill, four slash
skills (`/harness-route`, `/harness-gates`, `/harness-check`,
`/harness-remember`), and thirty subagents. It has no hooks, no MCP server
and no executable.

```sh
claude --plugin-dir ./priv/plugin
```

Without the engine, the subagents and the skill's method work, and the slash
skills say that the engine is missing. The plugin's README says exactly what
each part does in each case.

## How it was written

The harness was written with AI coding agents, under the direction of the
person who owns this repository. The agents worked through the harness
itself: each change was routed, recorded in a run ledger with evidence, and
closed only on a lane of gates that passed.

## Credits

- Four rules of the agent constitution take their ideas, and not their text,
  from the `AGENTS.md` of [pi](https://github.com/earendil-works/pi):
  - stage the files you changed and only those;
  - read a file in full before a wide change to it;
  - never weaken code to satisfy a tool, and upgrade the dependency instead;
  - ask before removing something that looks deliberate.
- The `simplify` skill in the starter pack is adapted from pi's `deslop`
  prompt, under the MIT License (`NOTICE`, `LICENSES/MIT.txt`).
- The evolution policy's frozen metrics, ordered gates and closing holdouts
  (`priv/starter/.agents/policies/evolution.md`) follow SoL-Pi
  (arXiv:2609.20519).

## Licence

Apache License 2.0 (`LICENSE`). Copyright NoeticEcho contributors. `NOTICE`
lists the third-party material and its licence.

Contributing: `CONTRIBUTING.md`. Security reports: `SECURITY.md`.
