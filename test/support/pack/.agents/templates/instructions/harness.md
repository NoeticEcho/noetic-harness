## The development harness, for an agent that is not Claude Code

This repository develops itself through `.agents/` — roles, gated workflows, a
run ledger, a project memory. Claude Code reaches it through hooks on every
prompt; **you have no such hooks, so ask.** The `noetic-harness` MCP server
(`noetic-harness mcp`, configured for this repository) serves it read-only:
{{mcp_tools}}. Before non-trivial work call `harness_route` with a one-line
title, then `harness_context` and `harness_memory`. A wrong route is a line in
`.agents/registry/signals.json`, not a workaround.

Nothing over MCP records or writes. Do that in a shell, and always through
`noetic-harness`, never a bare `mix` (which fails here with "No version is set for
command mix" — a missing toolchain, not a broken repository):
`noetic-harness run --start <WF> --title "..." --bead <id>`, then
`run --step <step> --outcome done --evidence "<what you ran and saw>"`, then
`run --finish`, which runs the gate lane itself. Lessons go in with
`noetic-harness memory --add`. Track work in `bd` (a cloud worker has none: its brief is its task list); stage explicit paths and never
`git add -A`; a gate that could not run is `unavailable`, not `passed`.
