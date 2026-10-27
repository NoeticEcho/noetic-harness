---
name: qdrant
description: Qdrant as a retrieval accelerator — what it is allowed to be used for and what it may never be cited as. Load for vector, embedding or neighbour-search work.
---

# Qdrant

Qdrant is a **retrieval accelerator**, never an epistemic source of truth.
It finds candidates. TypeDB says what is true.

The distinction is operational, not philosophical: a nearest neighbour is a
suggestion with a distance attached, and a distance is not evidence. An answer
that cites a vector search result as a fact has skipped the step where the fact
was checked.

## What it is for here

Giving a motif neighbours it could not have found by theme. The tests that
prove this are tagged `:qdrant` — five of them — and they need the vector store
running. CI has Postgres alone and excludes them, and each `test_helper.exs`
prints which way it went, because a test that silently does not run is worse
than one that is missing.

```bash
QDRANT_URL=http://localhost:6399 mix test    # asks the question CI asks
curl -s localhost:6333/                      # what version is actually running
```

## Rules

- Re-index is a data operation with a cost; `mix kb.load --reindex` is
  not a routine step.
- An embedding model change invalidates every stored vector. That is a
  migration, and it needs the same compatibility thinking as a schema change.
- Collection configuration (distance metric, dimensionality) is part of the
  contract. Changing it silently makes every stored vector meaningless while
  everything continues to appear to work.
