---
name: testing-phoenix
description: ExUnit, LiveView integration, fixtures, mocks, contracts and browser testing boundaries.
---

# Testing

Test at the lowest useful layer:
- pure domain;
- context integration;
- LiveView interaction;
- browser E2E only for user behavior.

Keep ordinary tests deterministic and isolate external services behind behaviours.
