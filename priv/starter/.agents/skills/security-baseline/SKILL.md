---
name: security-baseline
description: The security checks every change gets: untrusted input, secrets, dependencies, and the trust boundaries a change crosses.
---

# Security baseline

For every change, ask:

- **What input does it trust?** Anything from a user, a file, a network call or
  another service is untrusted until validated. Parameterise queries; escape
  output for where it goes.
- **Does it touch a secret?** Credentials come from the environment or a secret
  store, never from the code, a commit, a log or a prompt.
- **What does it add to the dependencies?** A new dependency is new code you did
  not review. Check it is maintained, and run the dependency scanner.
- **Which trust boundary does it cross?** Name it, and say what stops a caller
  on the wrong side from doing more than intended.

A scanner that found nothing found nothing *it looks for*. Say which scanners
ran, and which could not.
