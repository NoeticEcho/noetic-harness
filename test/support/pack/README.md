# The pack

This is the registry the engine's own tests run on. Nothing
else reads it. `Noetic.Harness.Pack`, in `../pack.ex`, says what it holds and
how a test gets a root on it. A design note says why it exists.

`.agents/` is a copy of the development repository's definitions as they stood on 2026-09-30.
It does not follow the live registry. Change it only when an engine test needs
a definition it lacks. The domains that describe the development repository's
product were cut from it in an earlier change, because the pack is in the public
tree; `../pack.ex` says what went. Its `WF-020`, "Development evolution", is
the tests' own and not the starter's: the starter pack's `WF-020` is "Harness
evolution", the one `init` writes, and the two share an id and nothing else.
Two parts are the pack's own and were never the Acme project's:
`.agents/registry/project.json` and `.agents/skills/`. The files under `tree/`
are its own too: each test root links them in, so the context sources in
`project.json` have something to find.
