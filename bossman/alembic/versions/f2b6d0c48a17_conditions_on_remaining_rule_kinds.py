"""conditions on the remaining rule kinds

Punkt 3, second half. "A rule gets a filter" is now true for every kind that HAS a host scope:

    already had it   CheckRule, CheckAssignment, ConfigPolicy, RemediationPolicy,
                     OrchestrationPlanLink
    added before     NotificationRule (e5c8b2a71f36)
    added here       ComplianceRule, ScheduledJob, BusinessService, ConfigPolicySet

ScopeVars is deliberately NOT in this list and is not an oversight: resolve_scope_vars is called BY
build_match_context (to supply host_vars), so a variable set that evaluated conditions would recurse
into itself. Cutting that cycle is a design decision, not a column.

All four default to {}, which rule_conditions treats as "matches everywhere" — so nothing needs
backfilling and every existing rule keeps behaving exactly as before.

Revision ID: f2b6d0c48a17
Revises: e5c8b2a71f36
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "f2b6d0c48a17"
down_revision = "e5c8b2a71f36"
branch_labels = None
depends_on = None

#: table -> the rule kind it backs, so the log line names the concept and not just the table.
TABLES = {
    "compliance_rules": "ComplianceRule",
    "scheduled_jobs": "ScheduledJob",
    "business_services": "BusinessService",
    "config_policy_sets": "ConfigPolicySet",
}


def _has(table: str) -> bool:
    return op.get_bind().execute(
        sa.text(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name = :t AND column_name = 'conditions'"
        ),
        {"t": table},
    ).first() is not None


def _table_exists(table: str) -> bool:
    """Checked per table because these features arrived at different times; a database that predates
    one of them must not fail the whole migration over a table it never had."""
    return op.get_bind().execute(
        sa.text("SELECT 1 FROM information_schema.tables WHERE table_name = :t"), {"t": table}
    ).first() is not None


def upgrade() -> None:
    for table in TABLES:
        if _table_exists(table) and not _has(table):
            op.add_column(
                table,
                sa.Column(
                    "conditions",
                    postgresql.JSONB(astext_type=sa.Text()),
                    nullable=False,
                    server_default=sa.text("'{}'::jsonb"),
                ),
            )


def downgrade() -> None:
    """Drops the columns, and with them any authored filters.

    The direction that matters: a rule that was narrowed to a group becomes a rule that applies to its
    whole scope. For ComplianceRule and ScheduledJob that means acting on MORE hosts than intended, and
    for BusinessService it means aggregating hosts that were deliberately excluded. Widening, not
    narrowing — worth knowing before running this anywhere real.
    """
    for table in TABLES:
        if _table_exists(table) and _has(table):
            op.drop_column(table, "conditions")
