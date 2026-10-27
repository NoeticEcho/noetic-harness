---
name: oban-workflows
description: Durable multi-step workflows, fan-out/fan-in and human approval using Oban.
---

# Durable Workflows

Represent workflow progress explicitly:
```text
state → job → durable result → next job
```

For fan-out/fan-in:
- correlation id;
- bounded concurrency;
- partial-failure handling;
- idempotent join.

For human approval, persist the waiting state and resume from an auditable event.
