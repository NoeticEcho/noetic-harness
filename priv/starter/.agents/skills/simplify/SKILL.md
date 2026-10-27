---
name: simplify
description: A scoped clean-up pass after the work is done: only the changed files, proposals first, approval before edits, tests after each change.
---

# Simplify

A scoped clean-up pass, run **after** the work is done and its tests pass.
Simplifying during implementation removes things before you know what they
were for.

This skill is adapted from the `deslop` prompt in
[earendil-works/pi](https://github.com/earendil-works/pi) (`.pi/prompts/deslop.md`),
Copyright (c) 2025 Mario Zechner, MIT License. The framing kept from it is a
scoped pass with an approval step, rather than a licence to tidy.

## Scope

Only the files the change touched. Code outside the diff is not yours to tidy
in this pass.

## What to look for

- Code that repeats something the codebase already has a function for.
- Comments that restate the code rather than say why.
- Defensive checks for states the code cannot reach, and fallbacks nobody asked
  for.
- Names that describe how instead of what.
- Abstractions with one caller that make the code harder to read.

## How

1. List what you would change, each with the reason, and **wait for approval**.
2. Make the approved changes, one kind at a time.
3. Run the tests after each. A simplification that changes behaviour is not a
   simplification.

Never remove something that looks deliberate without asking: a comment that
explains itself, a validation, a fallback someone relies on.
