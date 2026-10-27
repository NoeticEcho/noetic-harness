# Schemas

These are JSON Schema (draft-07) documents describing the shape of every
structured artifact the harness reads or writes.

**What actually validates them.** `mix harness.validate` runs
`Noetic.Harness.Validation.Schema`, a deliberately small subset evaluator:
`type`, `required`, `properties`, `additionalProperties`, `items`, `enum`,
`pattern`, `minItems`, `const` and `$ref` to a local `#/definitions/…`. It does
not implement `allOf`/`anyOf`/`oneOf`, `if`/`then`, numeric bounds or format
assertions, and it says so when it meets one rather than passing silently.

That subset is enough for these documents and keeps the harness at zero
dependencies. Anything a schema cannot express — that every referenced skill
resolves to a file on disk, that gate holders name real roles, that a workflow
graph has no unreachable step — is checked by the reference validator in
`Noetic.Harness.Validation`, which is where the interesting failures live.

A `$schema` pointer in a data file must resolve to a file here. A dangling
pointer fails validation; it is exactly the kind of drift these documents exist
to prevent.
