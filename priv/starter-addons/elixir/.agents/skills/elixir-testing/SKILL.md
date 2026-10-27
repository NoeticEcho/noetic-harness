---
name: elixir-testing
description: How to test Elixir with ExUnit: async where safe, one behaviour per test, doctests for examples, and a test that fails without the change.
---

# Testing Elixir

- **`async: true` unless the test touches global state**: the application
  environment, a named process, the file system, a shared database without the
  sandbox. Say why above the `use` line when it cannot be async.
- **One behaviour per test**, named as a sentence about that behaviour.
- **Doctests keep examples honest.** An example in a `@doc` that is not a
  doctest will drift.
- **Run the new test without the change first** and watch it fail, or it does
  not test the change.
- **Tag what needs a service** (`@tag :database`) and have `test_helper.exs`
  say which tags it excluded, so a skipped test is visible.
