---
name: supervision-design
description: Supervision trees, application children, restart strategies and failure boundaries.
---

# Supervision

For each child ask:
- who owns it?
- what state can be lost?
- what should restart?
- what happens during startup ordering?
- how does partial dependency failure behave?

Prefer narrow ownership and explicit restart strategy.
Do not use supervisors as a code organization mechanism.
