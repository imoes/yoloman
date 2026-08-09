"""reclassify agent.mode: no 'standalone' for managed agents

A Bossman-managed agent is a Duppy (satellite) or a Selecta (proxy, fronts
satellites) — never 'standalone', which means an un-enrolled/self-managed agent
(bearer-only, no Bossman). Existing rows created with the old default get
reclassified: an agent with satellites (children) becomes 'proxy'; every other
managed agent becomes 'satellite'.

Revision ID: b8c9d0e1f2a3
Revises: a7b8c9d0e1f2
"""

from __future__ import annotations

from alembic import op

revision = "b8c9d0e1f2a3"
down_revision = "a7b8c9d0e1f2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Agents that front satellites → Selecta (proxy).
    op.execute(
        """
        UPDATE agents SET mode = 'proxy'
        WHERE mode <> 'proxy'
          AND id IN (SELECT DISTINCT parent_agent_id FROM agents WHERE parent_agent_id IS NOT NULL)
        """
    )
    # Every other 'standalone' row (a managed Duppy) → satellite.
    op.execute("UPDATE agents SET mode = 'satellite' WHERE mode = 'standalone'")


def downgrade() -> None:
    # One-way normalization; 'standalone' is no longer a stored role.
    pass
