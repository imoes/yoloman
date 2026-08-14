"""remediation_runs.action: WHAT ran, recorded at the time

A run only stored `runbook_name`, which is empty for a rule whose action is an event handler —
so the audit row for exactly the new case could not say what ran. Storing it rather than joining
back to the policy is deliberate: `remediation_runs.policy_id` is ON DELETE SET NULL, so a
deleted rule would take the answer with it and leave a history that lists events it cannot
explain.

Format is "kind:name" ("runbook:restart-nginx", "handler:clean-logs") — the kind is part of the
fact, because "clean-logs" alone would not say whether a runbook or a script ran.

Revision ID: b3e7d1a48c52
Revises: f7c2a8e14b93
Create Date: 2026-08-14 22:05:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'b3e7d1a48c52'
down_revision: Union[str, Sequence[str], None] = 'f7c2a8e14b93'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('remediation_runs', sa.Column('action', sa.String(), nullable=False, server_default=''))
    # Existing rows all came from the runbook-only era, so their action is knowable and is
    # backfilled rather than left blank — an empty column would be indistinguishable from "we do
    # not know", which is the state this change exists to remove.
    op.execute(
        "UPDATE remediation_runs SET action = 'runbook:' || runbook_name "
        "WHERE runbook_name <> '' AND action = ''"
    )


def downgrade() -> None:
    op.drop_column('remediation_runs', 'action')
