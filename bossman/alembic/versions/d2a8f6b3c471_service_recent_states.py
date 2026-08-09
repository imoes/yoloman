"""L7: services.recent_states — the result history flapping detection needs

Revision ID: d2a8f6b3c471
Revises: b8f4c2e17a93

Flapping was "5 state changes within 30 minutes", which is not normalised against how often
the service is actually checked: a service polled every 10 minutes can only produce three
results in that window and so could never flap, while one polled every 20 seconds flaps on a
handful of blips out of ninety checks.

Nagios/Checkmk instead keep the last 21 RESULTS and compute a weighted percentage of
transitions among them (recent transitions count more), with hysteresis so the flag itself
does not oscillate. That needs the results, not just the changes — `service_state_history`
records changes, deliberately, because it is the timeline a human reads.

A fixed-length JSONB array on the row rather than a new table: 21 entries never grow, need no
retention policy, and nothing ever wants an older window.
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "d2a8f6b3c471"
down_revision = "b8f4c2e17a93"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "services",
        sa.Column("recent_states", postgresql.JSONB(), nullable=False, server_default="[]"),
    )


def downgrade() -> None:
    op.drop_column("services", "recent_states")
