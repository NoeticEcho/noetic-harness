---
name: oban-workers
description: Oban workers, retries, uniqueness, queues, scheduling and durable background processing.
---

# Oban

Every worker defines:
- idempotency;
- retry policy;
- uniqueness;
- queue/concurrency;
- failure classification;
- observability.

Keep job args small.
Do not rely on process memory for durable workflow state.
Test retry/discard behavior.
Use Oban for durable execution, Jido for agent orchestration.
