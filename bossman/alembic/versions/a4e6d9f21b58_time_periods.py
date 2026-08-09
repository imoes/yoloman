"""L4: time_periods + notification_rules.time_period_id

Revision ID: a4e6d9f21b58
Revises: f3a9c1d47b62

"Only page me during business hours" and "this backup job is expected to be red at night"
were both unexpressible: NotificationRule had no time dimension at all.

Modelled as its own object rather than as fields on the rule, because the same window is
reused across rules and because a per-rule field cannot express exclusions (business hours
MINUS company holidays). Shape follows Checkmk's TimeperiodSpec.

`time_period_id` is nullable and NULL means "always" — which is exactly what every
existing rule already means, so nothing is backfilled and no rule has to point at a row to
keep behaving as before. ON DELETE SET NULL: deleting a window must widen a rule back to
always rather than orphan it or, worse, silence it.

24x7 is seeded as a built-in so a period can be selected explicitly and so `excludes` can
name it; the evaluator also answers for it when absent, so an unseeded deployment behaves.
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "a4e6d9f21b58"
down_revision = "f3a9c1d47b62"
branch_labels = None
depends_on = None

_ALL_DAY = '{"monday": [["00:00", "24:00"]], "tuesday": [["00:00", "24:00"]], "wednesday": [["00:00", "24:00"]], "thursday": [["00:00", "24:00"]], "friday": [["00:00", "24:00"]], "saturday": [["00:00", "24:00"]], "sunday": [["00:00", "24:00"]]}'


def upgrade() -> None:
    op.create_table(
        "time_periods",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("name", sa.String(), nullable=False, unique=True),
        sa.Column("alias", sa.String(), nullable=False, server_default=""),
        sa.Column("ranges", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("exceptions", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("excludes", postgresql.JSONB(), nullable=False, server_default="[]"),
        sa.Column("is_builtin", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )
    op.add_column(
        "notification_rules",
        sa.Column("time_period_id", postgresql.UUID(as_uuid=True), nullable=True),
    )
    op.create_foreign_key(
        "notification_rules_time_period_id_fkey",
        "notification_rules",
        "time_periods",
        ["time_period_id"],
        ["id"],
        ondelete="SET NULL",
    )
    # Seed the built-in. ON CONFLICT DO NOTHING so re-running against a database that
    # already has it (a hand-created row) is not an error.
    op.execute(
        f"""
        INSERT INTO time_periods (name, alias, ranges, exceptions, excludes, is_builtin)
        VALUES ('24x7', 'Always', '{_ALL_DAY}'::jsonb, '{{}}'::jsonb, '[]'::jsonb, true)
        ON CONFLICT (name) DO NOTHING
        """
    )


def downgrade() -> None:
    op.drop_constraint("notification_rules_time_period_id_fkey", "notification_rules", type_="foreignkey")
    op.drop_column("notification_rules", "time_period_id")
    op.drop_table("time_periods")
