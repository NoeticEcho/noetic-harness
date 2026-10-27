---
name: elixir-idioms
description: Elixir implementation, refactoring, pattern matching, behaviours, protocols, data transformations and process boundaries.
---

# Elixir Idioms

- Prefer pure functions and data transformations.
- Do not create a process simply to organize code.
- Use processes for runtime state, concurrency, isolation, supervision or scheduling.
- Keep side effects at explicit boundaries.
- Use structs for stable domain data.
- Use behaviours/protocols for explicit polymorphism.
- Use pattern matching and tagged return contracts.
- Keep business rules out of GenServers.
- Make process ownership and restart semantics explicit.
- Test pure logic without starting the full supervision tree when practical.

Before editing: identify process boundaries, behaviours, public APIs and relevant tests.
