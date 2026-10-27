---
name: finch-pools
description: Named Finch pools and high-throughput HTTP. When direct Finch is justified below Req, and what evidence justifies it.
---

# Skill: Finch Pools and High-Throughput HTTP

Use Finch directly only for measured needs that require low-level control.

## Suitable cases

- high-volume Data Fabric connector;
- long-lived streams;
- source-specific concurrency pools;
- exact pool tuning;
- pool telemetry/metrics;
- specialized HTTP/1 or HTTP/2 behavior.

## Rules

1. Define named pools under supervision.
2. Never create a pool per request.
3. Bound concurrency per source.
4. Measure checkout pressure and latency.
5. Treat HTTP/2 streaming back-pressure limitations explicitly.
6. Keep direct Finch code inside a narrow adapter.
7. Expose a domain-independent interface to the rest of the product.

Finch 0.23.0 is the current release observed on 2026-09-18.
