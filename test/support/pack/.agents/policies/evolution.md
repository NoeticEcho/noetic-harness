# Evolution Policy

The harness itself is an evolvable artifact: prompts, role topology, routing
rules, skills, workflows, evaluators and context strategy are all things that
could be better and are all things a metric can be gamed into looking better.

## The pipeline, and why each stage exists

```
candidate → sandbox → benchmark → holdout → transfer → anti-goodhart → archive → promotion
```

| Stage | Question | Skipping it means |
|---|---|---|
| sandbox | Does it run without touching production behaviour? | You changed production behaviour. |
| benchmark | Is it better on the suite that motivated it? | You have an opinion. |
| holdout | Is it better on tasks that did *not* select it? | You fitted the benchmark. |
| transfer | Does the gain survive a different task family? | You found a narrow trick. |
| anti-goodhart | Did it improve the measure or the thing? | See below. |
| archive | Is the lineage recorded, including the failures? | The next attempt repeats this one. |
| promotion | Has an independent role approved the change? | The candidate approved itself. |

**A candidate is not better because it passed the benchmark that selected it.**
That sentence is the whole policy. A benchmark gain with a flat or negative
holdout is the Goodhart signature and the candidate is quarantined, not shipped.

## A cluster shape must name the change it implies

`noetic-harness telemetry --clusters` is what the evolution loop reads to decide
what is worth changing, so adding a shape to it changes what the loop
optimises. That makes a shape the same kind of object as a metric, and it gets
the same discipline.

A shape is admitted when it can say, in the imperative and naming a file or a
command, what to do about the number. A shape that can only say *what the
number is* is not admitted — and the first example is the one that was already
there: "23 lessons share the scope `harness`" says this month's work was about
the harness. It passed the population floor, it was one of only two clusters
the tool reported, and it names nothing to do. Such a shape is reported under
"above the threshold, naming no change" rather than deleted, because the count
is true and a scope that clusters while *not* being the majority is the signal
the shape was reaching for.

The floor of ten observations applies to every shape without exception. Three
failures of the same kind out of three observations is all the data there is.

## Declare the metrics before you run anything, and then do not touch them

A candidate declares, at proposal time:

- **capability metrics with tolerances** — what must not get worse, and by how
  much it may move before that counts as worse;
- **efficiency metrics** — what the change is *for*;
- the **family** the idea came from: `context`, `progress`, `tools`,
  `delegation`, `prompt_policy` or `improvement_evaluation`. This classifies
  where the idea came from, not where the change is allowed to land.

These are **frozen** at proposal. `record_stage` refuses to change them, and
the reason is not tidiness: metrics an optimising agent can edit are metrics
an optimising agent will edit, and the edit will look like a result. This is
the same rule as "never modify the evaluator that judges you", applied to the
thing the evaluator measures.

## Two gates, in order, and then the nondominated set

1. **Every capability metric is within its declared tolerance.** A candidate
   that made something worse than it said it would is rejected, however good
   the efficiency number is.
2. **At least one declared efficiency metric improved.** A candidate that broke
   nothing and improved nothing is not a candidate.

Among the candidates that pass both, keep the **nondominated** ones — those
that no other candidate beats on every metric at once. There is deliberately no
scalar score to rank them by: a candidate better at three things and worse at
one has produced information, and collapsing that into a number throws the
information away in order to make the decision feel easier.

## A failed holdout rejects. It does not start another round.

When the holdout or the anti-Goodhart stage fails, the candidate is **rejected
and closed**. No further stages may be recorded against it. A new attempt is a
new candidate that names this one as a parent, so the failure stays in the
lineage instead of being edited out of it.

This is the difference between a holdout and a slow benchmark. If a failed
validation can be answered by another iteration on the same candidate, the
held-out tasks have entered the search loop and stopped being held out — which
is how an evolved harness comes to be excellent at exactly the tasks used to
evolve it and no others.

## The tasks those gates are to be scored on

`.agents/evolution/environments/` holds them: one file per environment, each
derived from a commit in this repository, each with a test file as its
verifier. `noetic-harness environments` lists them; `--verify <id>` runs one.

**An environment is kept only if its verifier fails against the pre-fix source
and passes at HEAD.** The criterion is SoL-Pi's (§2.3). Of thirteen derived,
eight verify, two are **rejected** — the test their commit added exercises the
feature and passes whether or not the fix is present — and three are
**unavailable**.

Two things this taught, both the hard way:

- A suite assembled without running each task both ways would have contained
  all thirteen and would have scored candidates on two tasks that cannot tell
  whether a candidate worked. One of those two is a fix from the session that
  wrote this paragraph.
- **A criterion is only as good as the patch it reverts.** The first version
  reverse-applied a commit's `apps/*/lib/**.ex` files and nothing else, so a
  commit whose real content was one `elixirc_paths` line in `mix.exs` had its
  fix left in place and was recorded as a test that does not discriminate. A
  false rejection is a finding filed against innocent work, and it is the same
  failure mode as a false pass wearing different clothes. The patch is now the
  whole commit minus its ExUnit files and prose, and an incomplete patch
  reports `unavailable`.

An environment that has not been verified — or that was verified once and has
stopped — is in **no set** and contributes to **no gate**. There is no flag to
relax this.

### The sets, and why assignment does not move

| Set | What it is for | Rule |
|---|---|---|
| `benchmark` | the suite a candidate was allowed to see | may motivate a change |
| `holdout` | tasks that did not select the candidate | never shown during generation |
| `transfer` | a different task family | should come from source the benchmark does not touch |

`assign/2` refuses to change an existing assignment. A holdout you can move an
environment out of, after a candidate failed on it, is not a holdout — and the
move never looks like cheating from the inside. It looks like curation.

Two environments in different sets may not share a verifier file: a shared file
puts one set's answers on screen while somebody works on another's. They may,
today, share a **source** file, and five do. That is a warning rather than an
error, and the honest statement is that the holdout property here rests on the
one-way assignment and not on source isolation. The transfer set has the same
problem in larger form — with the patch widened to whole commits, nearly every
environment touches both `acme` and `acme_web` — and `validate/0` says so
every run rather than the sets being re-cut until it stops complaining.

### What the verification can and cannot say

`verified` and `rejected` are statements about the test. `unavailable` is a
statement about our ability to ask — the fix no longer reverse-applies, the
patch does not cover the whole commit, a worktree could not be opened, HEAD
itself does not pass — and it is never reported as either of the other two. A
set member that becomes `rejected` is a validator error; one that becomes
`unavailable` is a warning, because making the honest action the one that turns
a blocking gate red is how you teach people to stop re-verifying.

**"Failed before the fix" is satisfied by a tree that does not compile.**
Reverse-applying a commit that created a module deletes it, and every test in
the file then fails for the same uninformative reason. Those environments are
real tasks and they are not evidence that their verifier discriminates
anything: the record carries `discrimination: "compile"` against `"assertion"`,
and `validate/0` warns. Two of the eight are in that state.

Twenty-two of this repository's thirty-six lib-and-test commits cannot be
verified this way at all, because their source has moved too far to
reverse-apply. Verifying those needs the worktree checked out at the fix's
*parent* rather than at HEAD — a second verifier kind, an earlier change. They are
absent from the suite rather than assumed.

### Where a verification runs

**In a git worktree of its own, at HEAD, which is then thrown away** — the same
machinery a design decision gives a dispatched run. It used to run in whatever working
tree the caller was standing in, and all three consequences were real and
unhandled: a verification reverse-patched shared source under another agent
session, `git apply` restored the files and could not restore a `_build` left
compiled from reversed source, and no verification could run beside anything,
including a second verification.

A verdict is therefore **about HEAD**. Uncommitted work in the paths the
verifier reads is no longer a refusal — the worktree makes that refusal
pointless — and is recorded as a note saying the verdict is not about it.

**What it costs, measured rather than assumed.** A fresh worktree has no
`_build`, and a cold umbrella build is the whole cost of a verification:
`env-nex-payload-contract` took **7m06s** that way. Seeding the worktree with
the dependencies' build artifacts — and only those, because the umbrella's own
five apps are what a concurrent session is rewriting while you copy — brings it
to **1m35s** for the same verdict. Every dependency is copied whichever app the
environment belongs to, so a `noetic_harness` environment pays the same copy
and finishes in 29s because it has nothing else to build.

**A broken build is not a verdict.** The second pass fails non-zero when the
verifier detects the defect and also when `mix` never reached the tests, and
until an independent review said so, both were written down as `verified`
behind a warning-level `discrimination: "compile"`. Seeding a fresh worktree is
what made the second reachable. A `** (Mix)` error or a dependency that will
not compile is now `unavailable`; a `CompileError` in the app under test stays
`verified`, because a reverse patch that deletes a module is a real task.

The worktree isolates the filesystem and **not Postgres**. Two verifications of
database-touching environments share `acme_test` and rely on the Ecto sandbox
exactly as the ordinary suite does; `MIX_TEST_PARTITION` is the lever if that is
ever not enough, and it is not pulled because nothing has needed it.

Evidence is redacted **by value** — every credential-shaped environment
variable this process holds, wherever it appears in the output — and evidence
that still carries a `scheme://user:password@host` run is *withheld* with a
sentence saying so rather than filtered quietly. `verification.by` is a claim
the runner made about itself and is recorded beside `by_attested: false`, so a
gate cannot read the name without reading that nothing checked it.

### A number is not a measurement until something can be pointed at

`benchmark`, `holdout` and `transfer` are the three values the promotion gate
rests on, and until an earlier change nothing tied them to the suites of the same name.
`goodhart_signature?/1` read the literal strings `"benchmark"` and `"holdout"`;
they agreed with the set names by coincidence, and `transfer` — a required
stage — fed nothing at all, so a candidate could pass a transfer whose number
never entered a gate.

Now: the keys are `Environments.sets/0`, the signature is a benchmark gain with
a flat or negative **holdout or transfer**, and a set-keyed value must carry
`fitness_provenance`:

```json
"fitness_provenance": {
  "benchmark": {"run": "<run id>", "at": "...", "environments": [...]}
}
```

Refused: a value that is not a number; a value with **no provenance**, which was
typed rather than measured; provenance naming a run that is **not in the
ledger**; `environments` that is not a list of ids; recorded members that are
not **exactly** the set's currently verified ones, in either direction — a
member has stopped verifying and the number is about a suite that no longer
exists, or one was added and the number is a rate over part of a suite wearing
that suite's name; and a set with **no verified members left**, which used to
make the comparison vacuous and the guard a no-op at exactly the moment a
number about that set is worth the least.

`promotable?/1` and `nondominated/1` both consult it. The second matters as
much as the first: the nondominated set is *the set a human chooses from*, and
a hand-typed number that dominates could delete a measured candidate from it
without any gate being opened.

What this does **not** establish, stated here because an independent review
forged a promotable candidate against the first version of it: a run id that
resolves is a file in `.agents/runs/` that a commit records, not proof that the
run measured anything. A person can write that file. The check makes a forgery
leave a trace in the ledger, which is the difference between a lie and an
unfalsifiable claim, and nothing more. Proof needs an attested identity.

Only the three set keys are governed this way. Capability and efficiency
metrics are declared per candidate and measured however its hypothesis says.

The check lands **before** anything writes such a number — scoring is
An earlier change — on purpose. A gate added after the thing it gates is a gate that
has already been passed around once.

### Independence is a question about runs, not about names

`holdout` and `anti_goodhart` must be independent of the candidate's author,
and until an earlier change that was `by != created_by`: two strings the same process
wrote, answerable by typing a different name. After dispatch both are written
by the same loop, so the check was about to stop meaning anything at exactly
the moment it started mattering a thousand times a day.

What is harder to rename is the **ledger**. A candidate records the run it was
proposed in. A scoring run records its own id in `fitness_provenance`.
`Run.ancestor?/2` walks `parent_run`, the same chain the depth ceiling and the
stop already walk — so scoring from a child run, the obvious laundering path,
is the same refusal. A held-out number produced by the candidate's own run, or
by anything that run dispatched, is refused.

That chain is now one something can build. `Dispatcher` exports
`NOETIC_HARNESS_PARENT_RUN` around the call and `Run.start/1` reads it, so a
run an agent opens while it is being dispatched is a *child*; `noetic-harness run
--start --parent-run <id>` is the same thing by hand, and it refuses a parent
that is not in the ledger. Before that, nothing outside the test suite wrote a
non-`nil` `parent_run` at all: the walk described a path that could not be
taken, while the path that could — starting a sibling run — was refused by
nothing. An independent review found the discrepancy in this paragraph.

The walk **fails closed**. A chain that cannot be walked to the top — a cycle,
a run whose parent file is gone, a chain past the 50-run ceiling — answers
"cannot establish independence", not "independent". Otherwise the ceiling is
itself the laundering path.

The benchmark is deliberately not covered: it is the suite a candidate was
*allowed* to see, and refusing the author's own benchmark run would refuse the
ordinary case.

A scoring run that may not record what it measured **returns the numbers
anyway**, with the reason the ledger would not take them. A measurement nobody
may write down is not a measurement that did not happen.

Two residuals, stated rather than closed. Both run ids are fields in files a
person can edit: what the check buys is that each has to *resolve* — a run the
ledger records and `noetic-harness run --status` will print — so a forgery leaves
a trace instead of being an unfalsifiable claim. And a human who starts two
unrelated runs by hand is the author of both, which nothing here detects; an
author who repoints a candidate's `run` at somebody else's real run defeats the
walk the same way. `by` is self-asserted, and an attested identity is an earlier change.
What this closes is the *automatic* path — the one that will actually be
taken.

## Anti-Goodhart checks

At minimum, for any promotion:

- an evaluator the candidate's author did not write and cannot modify;
- held-out tasks not visible during candidate generation;
- adversarial cases aimed at the specific shortcut the mutation enables;
- a transfer suite from an adjacent task family;
- the existing regression corpus, unchanged;
- human review for anything touching the constitution, gates or trust levels.

Never collapse the result into one global score. A candidate that is better at
three things and worse at one has produced information, not a number.

## Archive

Failed candidates are kept with their lineage and their failure reason. They are
stepping stones: the next mutation frequently starts from something that did not
work on its own. `.agents/evolution/archive/` is append-only, like memory.

## Prior art

This pipeline was designed before we read *SoL-Pi: Recursively Scaling
Auto-Research Loops for Efficient Agent Harness* (Liu et al., NVIDIA/NTU/MIT,
[arXiv:2609.20519](https://arxiv.org/abs/2609.20519)), and four of its
conclusions arrived at the same shapes from a much larger search — roughly 150
proposed directions over ~500 executable environments. Where it is sharper than
we were, we took the sharpening:

- **Metrics frozen before experimentation and isolated from the optimising
  agent's control**, "to prevent it from gaming the acceptance criteria". We
  had the rule for evaluators and not for the metrics themselves.
- **Two sequential gates then a nondominated set** — the structure above is
  theirs. We had the no-scalar-score principle without the gates that make it
  operational.
- **"A failed validation rejects the candidate without triggering further
  optimization."** We allowed a candidate to keep running stages after a failed
  holdout, which quietly readmits the holdout into the search.
- **A two-tier holdout**: they reserve 11 of 51 tasks for one-way acceptance of
  frozen candidates and 40 for final generalization, which is our
  `holdout` → `transfer` split with the sample sizes written down.

Their four token-efficiency mechanisms (Action Fusion, Online Context Compact,
ObservationPack, Evidence-Preserving Reducer) are **not** adopted: they modify
an agent loop this repository does not own. The one place their numbers touch
ours is `Noetic.Harness.Context`, whose excerpt caps cite them as prior art.

## What may not evolve automatically

The constitution, trust levels, the security policy, gate definitions and the
source-of-truth separation change only through a human-reviewed ADR. An
evolution run may *propose* a change to them. It may never land one.
