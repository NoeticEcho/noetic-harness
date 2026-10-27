# Contributing

Thank you for looking. Issues and pull requests are welcome.

## Before a pull request

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

CI runs the same four on Linux and macOS. There is no Credo: the engine does
not use it, and `compile --warnings-as-errors` and `format` are the checks.

Some tests are excluded here, and the suite prints each tag and why:
`:this_repository` and `:git_history` are about the repository the harness
was developed in, `:asdf` about its toolchain scripts, `:aw` needs an `aw`
workspace identity, and `:live` calls a real model and costs money.

## How the harness is changed

The harness develops itself the way it asks other repositories to be
developed. A change starts from a written reason. Its tests fail without it
and pass with it. A gate that could not run is reported as `unavailable`,
never as passed. The constitution in `priv/starter/.agents/constitution.md`
states the rules every role works under, and they apply to changes here too.

`priv/plugin/agents/` is generated from the starter pack by
`mix harness.plugin`, and a hand edit to it is reverted the next time it is
generated. `mix harness.plugin --check` says whether it is in step.

## Where this tree comes from

This tree is cut from the repository the harness is developed in, by a
`harness cut` task that stays there. The cut is deterministic: the same
commit gives the same bytes. It also writes `mix.exs`, `mix.lock`, `LICENSE`,
`NOTICE`, this file and the other files at the top of the tree. For now a
change made here is carried back into that repository and cut again, so a
merged pull request reappears in the next cut rather than being lost.

## What is not built yet

- A published release. `MIX_ENV=prod mix release` builds the single
  `noetic-harness` file with Burrito (the README says how), and
  `Noetic.Harness.CLI` is what it runs: each subcommand is the mix task of
  the same name, so there is no second implementation to keep in step.
  `.github/workflows/release.yml` builds and runs it for Linux and macOS on
  every push, and attaches both to the GitHub Release of a tag `v*`. No tag
  has been pushed yet.
- A Hex package.

## Licence

By contributing you agree that your contribution is licensed under the
Apache License 2.0, as the rest of the repository is.
