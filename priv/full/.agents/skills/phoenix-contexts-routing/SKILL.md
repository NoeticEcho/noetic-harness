---
name: phoenix-contexts-routing
description: Phoenix routers, controllers, contexts, plugs, boundaries and HTTP API behavior.
---

# Boundaries

Routes map transport to stable application boundaries.
Contexts own domain operations.
Controllers/LiveViews translate transport into domain calls.
Plugs remain focused on cross-cutting concerns.
Keep authorization at explicit boundaries.
Keep API error shapes stable and tested.
Avoid unbounded context modules.
