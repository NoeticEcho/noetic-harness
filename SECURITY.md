# Security

## Reporting a vulnerability

Please report a vulnerability privately, through GitHub's private
vulnerability reporting on this repository: the **Security** tab, then
**Report a vulnerability**. Do not open a public issue for it.

Say what you found, how to reproduce it, and which commit or release you
tested. Reports are read and answered by the maintainers as time allows.
There is no bounty and no promised response time.

## What is in scope

The engine runs the commands a repository's `.agents/policies/gates.json`
defines, as the user who runs it. A repository's definitions are code, and
running the harness on a repository you do not trust is running that
repository's code. That is by design, not a vulnerability.

In scope, for example:
- the harness writing outside the repository it was pointed at;
- a record in the run ledger claiming a gate passed when it did not run;
- the plugin reading a credential, or sending anything anywhere.

## Supported versions

The latest commit on `main`, and the latest release once there is one.
