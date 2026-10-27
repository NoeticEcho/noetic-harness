# Privacy: the noetic-harness plugin

This page covers `noetic-harness`, the Claude plugin in
[`priv/plugin/`](../priv/plugin/README.md), made by NoeticEcho.

**The plugin collects nothing and sends nothing to NoeticEcho.** It has no
server, no telemetry, no analytics and no account. It stores no data of its
own, and it asks you for no token or password.

**What it is.** Five skills and thirty subagents: text that tells Claude how
to work. It has no hooks, no MCP server and no executable, so installing it
runs nothing.

**What it runs.** Four of its skills are slash skills. When you invoke one,
it runs, in the repository Claude is working in:

- `noetic-harness`, the engine, if you have installed it;
- `git status`, to show what changed;
- `echo`, to say when the engine did not answer.

The fifth, `harness`, is a method. It asks Claude to check whether the
engine and an `.agents/` directory are there, and to run the engine's
commands as it works, with your permission as Claude Code asks for it.

**The engine** is separate software, installed separately, under the same
licence. It sends nothing to NoeticEcho either. It reads and writes your
repository's `.agents/` directory and runs the gate commands your repository
defines. It uses the network only where your own configuration tells it to:
a model provider's API, with your own key, if you set it up to dispatch
steps to one, and services your project names. Its record of its own timings
is a file in your repository, under `.agents/telemetry/`, and never leaves
your machine.

What Claude Code and the commands your repository defines send, and what is
kept, is governed by their providers' policies, not by NoeticEcho:
Anthropic's [privacy policy](https://www.anthropic.com/legal/privacy), for
Claude Code.

**Questions** go to the repository's issues:
<https://github.com/NoeticEcho/noetic-harness/issues>. See
[Support](plugin-support.md).
