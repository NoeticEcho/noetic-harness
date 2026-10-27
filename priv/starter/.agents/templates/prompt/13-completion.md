# Completion

Your task ends in exactly one of: {{task.terminal_states}}.

`DONE` requires all of:

{{completion}}

And, from the workflow:

{{workflow.completion}}

**Never convert uncertainty into success.** If you produced output but cannot
establish that it is correct, the state is `UNCERTAIN` and your report names the
evidence that would settle it. If you were stopped, the state is `BLOCKED` and
your report names who can unblock it. Both are legitimate answers. A `DONE` you
cannot defend is not.

Close with: state, evidence, what you changed, what you assumed, what remains
unverified, and what you recorded to memory.
