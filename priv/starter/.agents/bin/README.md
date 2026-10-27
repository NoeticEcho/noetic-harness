# Project commands

The gates run these. Each is an executable you write for your language:

| File | Called as | Exit non-zero when |
|---|---|---|
| `format` | `format [files]` | a file is not formatted (check only, never rewrite) |
| `lint` | `lint [files]` | the linter finds a problem |
| `build` | `build` | the project does not build |
| `test` | `test [files]` | a test fails; with no files, run every test |

A command that is missing makes its gate report `unavailable`, and the lane `partial`.
This directory is inside the evaluator fence: a dispatched run may not change it.
