"""Checkmk's six rule-condition fields on both rule engines

Our rules could only be scoped structurally: global / group / host / OU-subtree. Checkmk
expresses a condition with six fields (RuleConditionsSpec, cmk/utils/rulesets/
ruleset_matcher.py:106) — host_name (list or regex, negatable), host_folder, host_tags
(with $ne/$or/$nor), host_label_groups and service_label_groups (and/or/not groups), and
service_description (regex). Tags already existed on the agent but were never a condition;
labels did not exist as conditions at all.

One JSONB column per rule engine holds the whole condition, evaluated by
services/rule_conditions.matches(). JSONB rather than columns because the shape is a nested
and/or/not grammar, not a fixed set of scalars — and keeping Checkmk's own JSON shapes means
a condition stays readable across the two systems.

DELIBERATELY NOT ADOPTED: Checkmk's ordered rulesets with position-derived precedence. Ours
stays GPO (services/gpo.py). Decided: rule ordering is exactly the Checkmk complexity the
simpler UI exists to avoid. Conditions decide WHETHER a rule applies, GPO decides WHICH
applying rule wins — orthogonal, so taking the conditions costs nothing on the precedence
side.

Default '{}' means "no condition", which matches everything, so every existing rule keeps
behaving exactly as before.

Revision ID: d5a2c8b41f37
Revises: c4d8e1f6b920
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision = "d5a2c8b41f37"
down_revision = "c4d8e1f6b920"
branch_labels = None
depends_on = None


def upgrade() -> None:
    for table in ("check_rules", "check_assignments"):
        op.add_column(
            table,
            sa.Column("conditions", JSONB, nullable=False, server_default=sa.text("'{}'::jsonb")),
        )
    # Rules carrying a condition are the minority; a partial index keeps the common
    # "no condition" case out of it entirely.
    op.execute(
        "CREATE INDEX idx_check_rules_conditions ON check_rules USING gin (conditions) "
        "WHERE conditions <> '{}'::jsonb"
    )
    op.execute(
        "CREATE INDEX idx_check_assignments_conditions ON check_assignments USING gin (conditions) "
        "WHERE conditions <> '{}'::jsonb"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS idx_check_assignments_conditions")
    op.execute("DROP INDEX IF EXISTS idx_check_rules_conditions")
    for table in ("check_rules", "check_assignments"):
        op.drop_column(table, "conditions")
