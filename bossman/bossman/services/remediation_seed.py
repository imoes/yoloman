"""Seed the standard parameter-driven remediation playbooks.

Three ready-made runbooks a RemediationPolicy can bind to a check — restart a
service, restart a docker container, truncate a log file — each driven by a
single parameter (the policy supplies it, e.g. {"service": "nginx"}). Idempotent:
only inserts a runbook whose name is not already present, so a human-edited copy
is never overwritten.
"""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import DEFAULT_TENANT_ID, Runbook

_RUNBOOKS: list[dict] = [
    {
        "kind": "runbook",
        "name": "remediate-restart-service",
        "targets": None,
        "parameters": {"service": {"type": "string", "description": "systemd service unit to restart"}},
        "steps": [
            {"name": "Restart the service", "module": "service",
             "args": {"name": "{{ service }}", "state": "restarted", "enabled": True}},
        ],
    },
    {
        "kind": "runbook",
        "name": "remediate-restart-docker",
        "targets": None,
        "parameters": {"container": {"type": "string", "description": "docker container name or id to restart"}},
        "steps": [
            {"name": "Restart the container", "module": "shell",
             "args": {"cmd": "docker restart -- {{ container }}"}},
        ],
    },
    {
        "kind": "runbook",
        "name": "remediate-clear-logs",
        "targets": None,
        "parameters": {"path": {"type": "string", "description": "log file to truncate to zero length"}},
        "steps": [
            {"name": "Truncate the log file", "module": "shell",
             "args": {"cmd": "truncate -s 0 -- {{ path }}"}},
        ],
    },
]


async def seed_remediation_runbooks(session: AsyncSession) -> int:
    """Insert any missing standard remediation runbook. Returns how many were added."""
    added = 0
    for doc in _RUNBOOKS:
        exists = await session.scalar(select(Runbook.id).where(Runbook.name == doc["name"]))
        if exists:
            continue
        session.add(Runbook(
            tenant_id=DEFAULT_TENANT_ID, name=doc["name"], kind="runbook", folder="remediation", doc=doc,
            created_by="seed",
        ))
        added += 1
    return added
