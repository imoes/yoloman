"""event handlers: a reusable action (runbook or script), managed or local

An event rule's action was two columns on remediation_policies (runbook_name + params), so it
could neither be reused across rules nor be a script. This adds the action as its own object
and lets a policy point at one. runbook_name stays valid, so every existing policy keeps
working unchanged — see docs/event-handling.md.

The check constraints are the point, not decoration: they make the combinations that cannot
exist impossible in the type rather than something the UI must remember to refuse.
  * a runbook is a row in this database, so it cannot be `local`
  * a runbook needs its name; a script needs an interpreter
  * a managed script needs its source; a local one needs its file name
  * a local handler declares NO parameters — Bossman does not know a locally-placed script's
    contents, so any parameter list it offered would be guessed

Revision ID: f7c2a8e14b93
Revises: d1f6a83b9e42
Create Date: 2026-08-14 21:05:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = 'f7c2a8e14b93'
down_revision: Union[str, Sequence[str], None] = 'd1f6a83b9e42'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'event_handlers',
        sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text('gen_random_uuid()')),
        sa.Column('tenant_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('tenants.id', ondelete='CASCADE'), nullable=False),
        sa.Column('name', sa.String(), nullable=False),
        sa.Column('description', sa.String(), nullable=False, server_default=''),
        sa.Column('body', sa.String(), nullable=False),
        sa.Column('location', sa.String(), nullable=False, server_default='managed'),
        sa.Column('runbook_name', sa.String(), nullable=True),
        sa.Column('interpreter', sa.String(), nullable=True),
        sa.Column('source', sa.Text(), nullable=True),
        sa.Column('local_name', sa.String(), nullable=True),
        sa.Column('parameters', postgresql.JSONB(), nullable=False, server_default='[]'),
        sa.Column('timeout_s', sa.Integer(), nullable=False, server_default='300'),
        sa.Column('enabled', sa.Boolean(), nullable=False, server_default='true'),
        sa.Column('created_by', sa.String(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint('tenant_id', 'name', name='uq_event_handlers_tenant_name'),
        sa.CheckConstraint("body IN ('runbook', 'script')", name='ck_event_handlers_body'),
        sa.CheckConstraint("location IN ('managed', 'local')", name='ck_event_handlers_location'),
        sa.CheckConstraint(
            "(body = 'runbook' AND location = 'managed' AND runbook_name IS NOT NULL "
            " AND source IS NULL AND local_name IS NULL) OR "
            "(body = 'script' AND location = 'managed' AND interpreter IS NOT NULL "
            " AND source IS NOT NULL AND local_name IS NULL AND runbook_name IS NULL) OR "
            "(body = 'script' AND location = 'local' AND local_name IS NOT NULL "
            " AND source IS NULL AND runbook_name IS NULL AND parameters = '[]'::jsonb)",
            name='ck_event_handlers_body_shape',
        ),
    )

    op.add_column(
        'remediation_policies',
        sa.Column('event_handler_id', postgresql.UUID(as_uuid=True),
                  sa.ForeignKey('event_handlers.id', ondelete='RESTRICT'), nullable=True),
    )
    # Exactly one action per rule. RESTRICT above rather than CASCADE or SET NULL: deleting a
    # handler a rule still uses must be refused with a reason, because SET NULL would leave a
    # rule that fires and does nothing and CASCADE would delete the rule someone else wrote.
    op.create_check_constraint(
        'ck_remediation_one_action',
        'remediation_policies',
        "(runbook_name <> '' AND event_handler_id IS NULL) OR "
        "(runbook_name = '' AND event_handler_id IS NOT NULL)",
    )


def downgrade() -> None:
    op.drop_constraint('ck_remediation_one_action', 'remediation_policies', type_='check')
    op.drop_column('remediation_policies', 'event_handler_id')
    op.drop_table('event_handlers')
