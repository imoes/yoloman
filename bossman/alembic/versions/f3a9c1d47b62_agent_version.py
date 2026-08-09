"""agents.agent_version — the agent's own build version, observed per poll

Revision ID: f3a9c1d47b62
Revises: e7b2f4a19c33

Checkmk surfaces the agent version as part of its agent service, and an operator needs it
before any question about behaviour can be answered ("is that host still on the collector
from before the fix?"). The agent already publishes it on its unauthenticated /healthz
(`{"status":"ok","version":"0.57.36"}`, cmd/agentic-mcpd/http.go), so nothing changes on
the agent side — Bossman just stores what it reads.

Empty string rather than NULL-with-a-default: "" means "not asked / never answered", and a
host that has genuinely reported nothing must not be presented as if it had a version.
"""

import sqlalchemy as sa
from alembic import op

revision = "f3a9c1d47b62"
down_revision = "e7b2f4a19c33"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "agents",
        sa.Column("agent_version", sa.String(), nullable=False, server_default=""),
    )


def downgrade() -> None:
    op.drop_column("agents", "agent_version")
