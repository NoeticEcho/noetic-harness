---
name: otp-design
description: How to design processes and supervision in OTP: what needs a process, what restarts, what owns state, and how to test the failure path.
---

# OTP design

- **A process is for state, concurrency or isolation.** Name which one before
  adding it.
- **Draw the supervision tree** before and after the change: what restarts
  together (`one_for_all`), what alone (`one_for_one`), what must start first.
- **Let it crash, deliberately.** A process should fail loudly on a state it
  cannot handle; its supervisor restores a known state. Catching everything
  turns a crash into silent corruption.
- **Messages to a name that is not registered are dropped.** `GenServer.cast`
  returns `:ok` either way, so silence is not delivery.
- **Test the failure path**: kill the process in a test and assert what the
  system does next.
