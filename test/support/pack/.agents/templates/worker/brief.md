<!-- A coordinator's brief to a cloud worker. Fill the
<…> parts and send everything below the line with
`claude -p '<brief>' --cloud <session url>`. The first line is the one the
worker's protocol takes an epic from; keep its shape.

The `## Terms` section is generated, not written: run

    noetic-harness context --format brief-terms --title "<the first line> <the title>"

and paste its output in place of the placeholder. Then check the whole brief,
or the coordination record it is kept in:

    noetic-harness context --check-brief <file>

which reports a brief with no `## Terms` section, a line of it that names no
glossary id, and an id that `docs/kb/glossary.json` does not have. A term you
add by hand needs its `term:` id for the check to see it. -->

---

EPIC <id>: branch claude/<id>-<slug>, scope <paths>, grants <paths>

**<The epic's title, in a sentence.>**

## Why now

<What landed, what it made possible, and what the person asked for, quoted.>

## Terms

<Replace this section, heading and all, with the output of
`noetic-harness context --format brief-terms`. A `contested` or `proposed` term
is a question for the person, not an answer: say under it which way this epic
takes it, or ask.>

## The epic

- **<child id>**: <what it delivers, and how it is tested.>

## Protocol

CLAUDE.md, *If you are a cloud worker*: WF-021, the handoff, WIP pushes,
`run --finish`, the pull request against develop. End with
`EPIC <id> READY <S> <pr-url>`.
