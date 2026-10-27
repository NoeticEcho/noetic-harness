## The development harness, for an agent without hooks

This repository develops itself through `.agents/`: roles, workflows with gates,
a run ledger, and a project memory. Claude Code reaches it through hooks;
**other agents should ask.** The `noetic-harness` MCP server serves it
read-only: {{mcp_tools}}. Before non-trivial work call `harness_route` with a
one-line title, then `harness_context` and `harness_memory`. A wrong route is a
line in `.agents/registry/signals.json`, not a workaround.

Nothing over MCP records or writes. Do that in a shell with the harness:
`harness run --start <WF> --title "..."`, then
`run --step <step> --outcome done --evidence "<what you ran and saw>"`, then
`run --finish`, which runs the gate lane itself. Lessons go in with
`harness memory --add`. Stage explicit paths, never everything, and remember
that a gate that could not run is `unavailable`, not `passed`.
