---
name: distributed-beam
description: Distributed Elixir nodes, clustering, PubSub, node discovery and Gigalixir scaling.
---

# Distributed BEAM

Start single-node until distribution is required.
When adding distribution define node discovery, trust, placement, state locality,
failure semantics and split-brain handling.

Distributed Erlang is not durable storage. Keep durable state in explicit stores.
Choose either dns_cluster or libcluster when needed; do not add both casually.
