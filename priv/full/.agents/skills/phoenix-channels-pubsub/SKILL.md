---
name: phoenix-channels-pubsub
description: Phoenix Channels, PubSub, Presence, WebSockets, realtime broadcasts and topic authorization.
---

# Realtime

Separate transport, topic semantics, authorization and domain event production.

- authenticate private topics;
- define topic naming contracts;
- keep PubSub payloads small;
- treat PubSub as delivery, not durable storage;
- design idempotent consumers when repeated delivery is possible;
- test joins, authorization and broadcast behavior separately.
