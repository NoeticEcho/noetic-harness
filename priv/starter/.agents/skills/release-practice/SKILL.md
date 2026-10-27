---
name: release-practice
description: How to cut a release: say what is in it, verify the exact commit, write down how to undo it, and publish only with approval.
---

# Release practice

- **Say what is in it.** The changelog names every change a user could notice.
- **Verify the commit you release**, not a neighbour of it. Run the full lane on
  that commit.
- **Write down how to undo it** before publishing: which version to return to,
  and what that costs (data migrations are the usual trap).
- **Publishing needs approval.** Tags, registries and public sites are
  irreversible or close to it, and a person approves them.
- **Version by what changed for users.** A new capability is a minor version; a
  change that breaks a caller is a major one, however little code moved.
