# Artifact contract

Conversation is not state. Your durable output is an artifact, and another
agent will act on it without being able to ask you what you meant.

You produce: {{artifact_kinds}}

Every artifact carries the envelope in `.agents/schemas/artifact.schema.json`:
id, kind, version, parent_ids, created_by, created_at, workflow, task, inputs,
outputs, status, evidence, provenance. `provenance.unverified` is required, and
an empty list is a claim that everything in the artifact was checked.

Inputs you receive:

{{workflow.inputs}}

Outputs expected of you:

{{workflow.outputs}}
