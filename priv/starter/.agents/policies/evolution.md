# Evolution Policy

The harness itself is an evolvable artifact: prompts, role topology, routing
rules, skills, workflows, evaluators and context strategy are all things that
could be better, and all things a metric can be gamed into looking better.

This policy binds every change made to the harness *because a number said
so*. Where the build has the evolution engine (`noetic-harness evolution` and
`noetic-harness environments`), the engine refuses what the sections below
forbid, and each refusal cites this file. Where the build does not have it,
nothing records a candidate: a change to the harness is an ordinary change,
reviewed as one, and the rules here are the reviewer's.

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
holdout is the Goodhart signature, and the candidate is quarantined, not
shipped.

## A cluster shape must name the change it implies

`noetic-harness telemetry --clusters` is what an evolution loop reads to
decide what is worth changing, so adding a shape to it changes what the loop
optimises. A shape is therefore the same kind of object as a metric, and it
gets the same discipline.

A shape is admitted when it can say, in the imperative and naming a file or a
command, what to do about the number. A shape that can only say *what the
number is* — "most lessons this month share one scope" — says where the work
was, and names nothing to do. It is reported as above the threshold and naming
no change, not deleted, because the count is true. Nothing files work for it.

The floor of ten observations applies to every shape without exception. Three
failures of the same kind out of three observations is all the data there is.

## Declare the metrics before you run anything, and then do not touch them

A candidate declares, when it is proposed:

- **capability metrics with tolerances** — what must not get worse, and by how
  much it may move before that counts as worse;
- **efficiency metrics** — what the change is *for*;
- the **family** the idea came from: `context`, `progress`, `tools`,
  `delegation`, `prompt_policy` or `improvement_evaluation`. This classifies
  where the idea came from, not where the change may land.

These are **frozen** at proposal. Metrics an optimising agent can edit are
metrics an optimising agent will edit, and a tolerance moved after a result is
in arrives looking like a result. It is the rule "never modify the evaluator
that judges you", applied to the thing the evaluator measures. A baseline is
the same thing one level down: it is taken once, and taking it again is a
deliberate act a reviewer can see.

## Two gates, in order, and then the nondominated set

1. **Every capability metric is within its declared tolerance.** A candidate
   that made something worse than it said it would is rejected, however good
   the efficiency number is.
2. **At least one declared efficiency metric improved.** A candidate that broke
   nothing and improved nothing is not a candidate.

Among the candidates that pass both, keep the **nondominated** ones: those no
other candidate beats on every metric at once. There is deliberately no scalar
score to rank them by. A candidate better at three things and worse at one has
produced information, and collapsing it into a number throws the information
away to make the decision feel easier.

## A failed holdout rejects. It does not start another round.

When the holdout or the anti-Goodhart stage fails, the candidate is **rejected
and closed**. No further stages are recorded against it. A new attempt is a new
candidate that names this one as a parent, so the failure stays in the lineage
instead of being edited out of it.

This is the difference between a holdout and a slow benchmark. If a failed
validation can be answered by another iteration on the same candidate, the
held-out tasks have entered the search loop and stopped being held out.

## The tasks a candidate is scored on

An environment is a task derived from a real commit of the repository — a
defect that was fixed, with the test that was added for it as its verifier.

**An environment is kept only if its verifier fails against the pre-fix source
and passes at HEAD.** A test that passes either way exercises the feature and
cannot tell whether a candidate fixed anything. An environment that has not
been verified, or was verified once and has stopped, is in **no set** and
contributes to **no gate**.

"Failed before the fix" is satisfied by a tree that does not compile. Reverting
a commit that created a module deletes it, and every test then fails for the
same uninformative reason. Such an environment is a real task and not evidence
that its verifier discriminates anything, and it is recorded as such.

`verified` and `rejected` are statements about the test. `unavailable` is a
statement about the ability to ask — the fix no longer reverts cleanly, the
build did not reach the tests — and it is never reported as either of the
other two.

**A solver is never shown the fix**: not in its working tree, and not in the
history it can read. A task whose answer is one `git show` away measures
whether the solver looked.

### The sets, and why assignment does not move

| Set | What it is for | Rule |
|---|---|---|
| `benchmark` | the suite a candidate was allowed to see | may motivate a change |
| `holdout` | tasks that did not select the candidate | never shown during generation |
| `transfer` | a different task family | should come from source the benchmark does not touch |

An existing assignment is never changed. A holdout you can move an environment
out of, after a candidate failed on it, is not a holdout — and the move never
looks like cheating from the inside. It looks like curation. Two environments
in different sets do not share a verifier file: a shared file puts one set's
answers on screen while somebody works on another's.

## A number is not a measurement until something can be pointed at

A benchmark, holdout or transfer value carries its provenance: the run that
measured it, when, and the environments it was measured over. Refused: a value
with no provenance, which was typed rather than measured; a run that is not in
the ledger; and a set of environments that is not exactly the set's currently
verified members, in either direction.

A run id that resolves is a file the ledger records, not proof that the run
measured anything. The check makes a forgery leave a trace, which is the
difference between a lie and an unfalsifiable claim, and nothing more.

## Independence is a question about runs, not about names

The holdout and the anti-Goodhart stage are independent of the candidate's
author. Two names the same process wrote are not independence: a number
produced by the candidate's own run, or by anything that run dispatched, is
refused. A chain of runs that cannot be walked to the top answers "cannot
establish independence", not "independent".

## Anti-Goodhart checks

At minimum, for any promotion:

- an evaluator the candidate's author did not write and cannot modify;
- held-out tasks not visible during candidate generation;
- adversarial cases aimed at the specific shortcut the mutation enables;
- a transfer suite from an adjacent task family;
- the existing regression corpus, unchanged;
- human review for anything touching the constitution, gates or trust levels.

Never collapse the result into one global score.

## Archive

Failed candidates are kept with their lineage and their failure reason. They
are stepping stones: the next mutation frequently starts from something that
did not work on its own. The archive is append-only, like memory: a candidate
in it is never removed, and a relabel to promoted passes the same gates as a
promotion.

## What may not evolve automatically

The constitution, the trust levels, the security policy, the gate definitions
and the source-of-truth separation change only through a decision a human
reviews. An evolution run may *propose* a change to them. It may never land
one, and the harness does not file it as a task in the work queue.
