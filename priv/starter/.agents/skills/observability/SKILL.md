---
name: observability
description: How to make software say what it is doing: structured logs, metrics that answer a question, and a check that the signal appears.
---

# Observability

- **Log events, not prose.** A structured log line with named fields can be
  searched; a sentence cannot.
- **A metric answers a question.** Decide the question first ("how long do
  requests to X take?"), then the metric.
- **Never log a secret or personal data.** Redact at the source.
- **Test the signal.** A log line or a metric nobody checked is one nobody knows
  is there. Assert that it appears.
- **During an incident, record what you saw, with times.** The timeline is
  built from evidence, not memory.
