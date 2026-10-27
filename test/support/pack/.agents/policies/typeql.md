# TypeQL Safety Policy

TypeDB is the source of truth for an avatar's character and meaning
and a read model for everything else, TypeQL is the only way to speak to it,
and model memory about TypeQL is unreliable in a specific, dangerous way: TypeDB
2.x syntax is abundant in training data and silently invalid in TypeDB 3.x. This
project runs TypeDB 3.13.

**Generated TypeQL is a draft. It becomes a query when a checker has read it.**

## The required sequence

```
1. inspect the live schema           — what types and roles actually exist
2. load the official typeql skill    — the one in .claude/skills/typeql/
3. read the repository's semantic model guidance
4. write or update the TypeQL
5. typeql-check                      — deterministic syntax gate, non-negotiable
6. run it against a sandbox database — syntax valid ≠ semantically right
7. run the fixture/query tests
8. inspect the diff
9. record what you learned in project memory
```

No step is optional, and steps 5–7 are three different questions:
`typeql-check` asks whether the parser accepts it, the sandbox run asks whether
the schema accepts it, and the tests ask whether it answers the question that
was posed.

## If `typeql-check` is not installed

Report it, install it (`scripts/install-tooling.sh`, sources in
`typedb/typedb-tools`), and if it cannot be installed, the TypeQL change is
`UNCERTAIN` — not `DONE` with a note. The gate reports `unavailable`.

## Schema changes are migrations

A change to the TypeDB schema is a migration with a compatibility question, a
rollout and a rollback, exactly like a Postgres migration. It is never a direct
edit against a live database. The code that writes TypeQL is pure, while the
loader that runs the queries lives in `acme_knowledge` — that separation is
A design decision and is not yours to collapse.
