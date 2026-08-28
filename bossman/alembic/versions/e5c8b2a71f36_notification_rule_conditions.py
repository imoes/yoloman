"""notification_rules.conditions — the shared rule-conditions object

Punkt 3 of the filter work: "a rule gets a filter" was true for 5 of 11 rule kinds. CheckRule,
CheckAssignment, ConfigPolicy, RemediationPolicy and OrchestrationPlanLink already carried
`conditions`; NotificationRule did not, so "notify only for these host groups" could not be said —
even though the same UI control now offers it everywhere the field exists.

Defaults to {} (no condition), so every pre-existing rule keeps behaving exactly as before: an empty
condition matches everywhere, by rule_conditions' own contract.

Deliberately ADDITIVE to the existing `tag_filter`. That column predates the shared conditions object
and is a narrower, cheaper subset match that live rules depend on; folding it in would migrate
notification behaviour, which is its own change with its own risk. The two are ANDed, which is what a
reader expects of two filters on one rule.

Revision ID: e5c8b2a71f36
Revises: d7a3f1c95e24
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "e5c8b2a71f36"
down_revision = "d7a3f1c95e24"
branch_labels = None
depends_on = None


def _has_column() -> bool:
    bind = op.get_bind()
    return bind.execute(
        sa.text(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name = 'notification_rules' AND column_name = 'conditions'"
        )
    ).first() is not None


def upgrade() -> None:
    # Guarded so the migration is safe on a database already built from the model, and idempotent if
    # re-run — the same shape the neighbouring migrations use.
    if not _has_column():
        op.add_column(
            "notification_rules",
            sa.Column(
                "conditions",
                postgresql.JSONB(astext_type=sa.Text()),
                nullable=False,
                server_default=sa.text("'{}'::jsonb"),
            ),
        )


def downgrade() -> None:
    """Drops the column, and with it any conditions that were authored.

    Said plainly: a rule that was narrowed to a group becomes a rule that fires for everything in its
    scope. That is a WIDENING of who gets paged, not a narrowing — worth knowing before running this
    on a system where someone relied on the filter.
    """
    if _has_column():
        op.drop_column("notification_rules", "conditions")
