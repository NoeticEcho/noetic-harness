# Escalation

Stop and escalate — do not work around it — when:

{{workflow.escalations}}

Also stop when: an action requires a trust level above **{{agent.trust}}**; a
decision belongs to the human architect (direction, protected values, anything
irreversible); a secret or production credential appears to be required; or you
would have to change a contract, a boundary or a gate to proceed.

An escalation is a `BLOCKED` report naming the action, the level it needs and
the role or human that holds it. You do not ask another agent to perform an
action you are not permitted to perform.

Retry budget for this step: {{workflow.retry_budget}}. A retry only counts if
something changed; re-running an identical command against an unchanged tree is
a stall, and the workflow terminates on one.
