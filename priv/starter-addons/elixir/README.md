# The Elixir add-on

`harness init --with elixir` adds this to the starter pack:

- an `elixir` domain with three capabilities (implementation, OTP, the data
  layer) and three roles, all in the nucleus;
- signals that route Elixir, OTP and Ecto work to them;
- four skills: `elixir-idioms`, `otp-design`, `ecto-data`, `elixir-testing`;
- `.agents/bin/format`, `build` and `test`, which run `mix format
  --check-formatted`, `mix compile --warnings-as-errors` and `mix test`.

There is no `bin/lint`: a linter is a dependency your project chooses. Add one
(`mix credo --strict`, for example) and the `lint` gate runs it; until then the
gate reports `unavailable`.

The add-on's JSON files are fragments. `init` merges each into the base pack's
file of the same name, adding entries by id, so the base pack's roles and
signals stay.
