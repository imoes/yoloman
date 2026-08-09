"""Block G11 (NT format, step 5): compile a NestedText Role into the
OrchestrationPlan create shape.

A role authored in NestedText (services/nt_runbook.Role) maps 1:1 onto the
existing OrchestrationPlan model — the compiler/binding/desired-state layers
are unchanged; this is just the authoring surface. steps -> the plan
version's steps; parameters -> default_parameters; monitoring.checks ->
generated_monitoring.checks ("what is orchestrated is monitored"); routes ->
generated_notifications.routes.
"""

from __future__ import annotations

from typing import Any

from bossman.services.nt_runbook import Role


def role_to_plan_input(role: Role, *, plan_type: str = "role") -> dict[str, Any]:
    """Return a PlanIn-shaped dict (see api/orchestration.PlanIn) ready to
    hand to the orchestration create-plan flow."""
    return {
        "name": role.name,
        "display_name": role.name.replace("_", " ").title(),
        "description": role.description,
        "plan_type": plan_type,
        "version": {
            "default_parameters": dict(role.parameters),
            "steps": [s.to_dict() for s in role.steps],
            "generated_monitoring": {"checks": list(role.checks)},
            "generated_notifications": {"routes": list(role.notification_routes)},
        },
    }
