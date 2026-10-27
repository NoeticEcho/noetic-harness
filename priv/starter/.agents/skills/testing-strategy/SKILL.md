---
name: testing-strategy
description: How to decide what to test and how: a test that fails without the change, tests at the level the behaviour lives at, and honest reporting of what was not run.
---

# Testing strategy

**A test that passes with or without your change tests nothing about it.** For a
bug fix, run the new test before the fix and watch it fail. For a feature,
write the test first when you can.

**Test at the level the behaviour lives at.** A rule inside one function is a
unit test. A rule about how two parts cooperate is an integration test. What a
user sees is an end-to-end test. Testing a rule two levels up makes the test
slow and its failures vague.

**Prefer properties where the input space is large.** A generator and an
invariant cover inputs nobody thought to write down.

**Flaky is a hypothesis.** Before calling a test flaky, find out why it
sometimes fails: a race, a shared resource, an unpinned clock, test order.
Instrument it. Retrying until green hides the defect.

**Report what did not run.** An excluded test, a skipped suite and a missing
service are unverified, not passed. Say which, and why.
