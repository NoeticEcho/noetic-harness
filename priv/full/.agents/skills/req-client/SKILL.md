---
name: req-client
description: Req as the default outbound HTTP abstraction: reusable request configuration, retries, pagination, rate limits.
---

# Skill: Req HTTP Client

Use Req as the default outbound HTTP abstraction in the product.

## Rules

- build reusable request configurations for related APIs;
- use explicit base URLs, headers and timeouts;
- classify status codes;
- retry only transient errors;
- honor Retry-After and source policy;
- validate response shape before domain mapping;
- instrument requests;
- use Req.Test for deterministic client tests;
- hide provider-specific behavior behind adapters.

Domain code should call the project HTTP boundary rather than `Req.get!` directly.

Req 0.7.4 is the current stable release observed on 2026-09-18. A 0.8.0 release
candidate exists; do not adopt it merely for novelty.
