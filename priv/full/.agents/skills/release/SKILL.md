---
name: release
description: Git flow, versioning, the release pipeline and rollback. Load before branching, merging, tagging or deploying.
---

# Release

Read `docs/guides/git-workflow.md` before branching.

## Git flow

`main` is what is released and tagged `vX.Y.Z`. `develop` is what is finished.
`feature/<bead-id>-slug` is one bead's work. **Merge with `--no-ff`, always** —
the merge commit is the record that a branch existed.

Semver is about the *product's contracts* — an API operation, a channel topic, a
resource attribute the client reads — not about how much code moved.

## An agent session does not pick its branch

The harness pins one, and pushing anywhere else needs to be asked for. That
branch *is* the feature branch for the session, however many beads it touches,
so the cycle is completed by hand at session close rather than skipped:

```bash
git switch develop && git merge --no-ff <pinned>
git switch -c release/vX.Y.Z develop        # bump all five mix.exs
git switch main && git merge --no-ff release/vX.Y.Z && git push origin main
git switch develop && git merge --no-ff release/vX.Y.Z && git push origin develop
```

The tag and the GitHub Release cannot be pushed from here — this remote refuses
every ref outside `refs/heads/*` with an HTTP 403 that only `--verbose` shows.
Trigger `release.yml` on `main` with the version instead.

This was written down after a release's worth of work sat on a pinned branch
while `main` stayed at `v0.1.0`. Merge at the end of a session, not at the end
of a month.

## Before pushing

`./scripts/ci-local.sh` runs the same three CI job bodies here, dropping
`my_app_test` first and pointing `QDRANT_URL` at a closed port so it asks the
question CI asks rather than an easier one. A minute against six. CI does not
watch `claude/**` any more.

## Push failures

`send-pack: unexpected disconnect while reading sideband packet` followed by a
misleading `Everything up-to-date` is transient — retry with backoff. Do not
conclude the push was refused by policy; check
`curl -sS "$HTTPS_PROXY/__agentproxy/status"` for a `recentRelayFailures` entry
naming `github.com` first. And note that `git push … | tail` reports the exit
status of `tail`, so a retry loop written that way declares success on every
failure.

## Rollback

Stated before deploy, not discovered after. A migration without a tested `down`
is not reversible, whatever the changelog says.
