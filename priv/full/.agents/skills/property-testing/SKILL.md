---
name: property-testing
description: Property-based tests for invariants, parsers, graph transforms, state machines and serialization.
---

# Properties

Useful the product properties:
- canonicalization is idempotent;
- serialize/deserialize round-trips;
- branch/merge preserves invariants;
- TypeQL generation passes checker;
- evolution lineage remains acyclic;
- SceneRecipe compilation is deterministic under locked inputs.

Use properties where examples are insufficient.
