# Provenance

An artifact with no provenance cannot be evaluated, only believed. This project
runs on evidence, so every durable thing the harness produces carries where it
came from.

## The envelope

Every artifact the harness writes conforms to
`.agents/schemas/artifact.schema.json`:

```yaml
id:          stable, sortable, unique
kind:        one of the artifact kinds below
version:     integer, incremented on revision
parent_ids:  the artifacts this one was derived from
created_by:  agent id
created_at:  UTC ISO-8601
workflow:    workflow id and step
task:        bead id
inputs:      what was read (paths, ids, queries)
outputs:     what was produced
status:      draft | proposed | accepted | superseded | rejected
evidence:    commands run and their results; never a claim without one
provenance:  {source, commit, tool_versions, unverified: []}
```

`provenance.unverified` is required and may not be omitted to mean "nothing".
An empty list is a claim that everything in the artifact was checked.

## Artifact kinds

```
Requirement  RFC  ADR  ArchitectureMap  TaskGraph  CodePatch  SchemaChange
Migration  AgentSpec  SkillSpec  WorkflowSpec  WorldSpec  TrajectorySpec
SceneRecipe  AssetManifest  DatasetManifest  Experiment  EvaluationRun
RenderEvidence  VisualCritique  ReleaseCandidate  IncidentReport  Postmortem
ResearchNote  Hypothesis  Benchmark  HoldoutResult  TransferTest  ProvenanceRecord
```

## Rules

1. **Lineage survives transformation.** An artifact derived from another names it
   in `parent_ids`. A GLB names the source asset and its licence. A benchmark
   result names the candidate and the suite revision.
2. **Evidence is a command and its output**, not a description of a command.
3. **Licence travels with assets.** An asset with unknown rights does not enter
   the repository. "Search before generate" only works if what you found records
   what you are allowed to do with it.
4. **Generated code records its generator** — the task, the model, the prompt
   revision — so a systematic defect can be traced to its source rather than
   found again in twenty files.
5. **Tool versions matter.** A benchmark run under a different Elixir, Node,
   TypeDB or GPU is a different benchmark. Record them.
