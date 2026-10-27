---
name: elixir-idioms
description: How Elixir code in this repository is written: pattern matching over conditionals, tagged tuples for failure, pipelines over nesting, and small public modules.
---

# Elixir idioms

- **Match, don't test.** Multiple function heads and `case` on shapes read better
  than `if` chains over fields.
- **Return `{:ok, value}` or `{:error, reason}`** from anything that can fail for
  a reason the caller should handle. Raise only for bugs. `with` chains the
  happy path.
- **Pipelines for transformations**, each step a named function. A pipeline
  whose first step is not data is usually a nested call in disguise.
- **Keep the public surface small.** `@doc false` or `defp` for what callers
  should not rely on, and a `@moduledoc` that says why the module exists.
- **No process without a reason.** Code that holds no state and needs no
  concurrency is a module of functions, not a GenServer.
- **Use the version in `mix.lock`.** Check a library's documentation for that
  version (`mix hex.docs` or hexdocs.pm with the version in the URL).
