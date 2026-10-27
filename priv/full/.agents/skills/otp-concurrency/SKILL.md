---
name: otp-concurrency
description: GenServer, Supervisor, Task, DynamicSupervisor, Registry, ETS and BEAM concurrency.
---

# OTP

First question:
> What runtime property requires a process?

Use processes for state, concurrency, isolation, supervision, scheduling or coordination.

- Task.Supervisor for managed concurrent tasks;
- supervisors define ownership/restart policy;
- avoid global GenServer bottlenecks;
- define message contracts;
- use back-pressure for unbounded workloads;
- test crash/restart behavior where it matters.
