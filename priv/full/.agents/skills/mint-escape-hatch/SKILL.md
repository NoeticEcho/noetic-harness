---
name: mint-escape-hatch
description: Mint as the transport escape hatch below Finch, and the architecture note every use of it requires.
---

# Skill: Mint Escape Hatch

Mint is the low-level transport layer below Finch.

Use it only when Req and Finch cannot express a required transport/protocol feature.

Every Mint usage requires an architecture note because it increases maintenance
surface and removes useful Req/Finch abstractions.
