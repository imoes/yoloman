"""agents: allow enrollment_state 'planned' (a configured-but-not-yet-installed provisioning target)

Revision ID: e4b2c1d8f6a3
Revises: d3f1a9c7e5b2
"""
from alembic import op

revision = "e4b2c1d8f6a3"
down_revision = "d3f1a9c7e5b2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_constraint("ck_agents_enrollment_state", "agents", type_="check")
    op.create_check_constraint(
        "ck_agents_enrollment_state", "agents",
        "enrollment_state IN ('planned', 'pending', 'enrolled', 'revoked')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_agents_enrollment_state", "agents", type_="check")
    op.create_check_constraint(
        "ck_agents_enrollment_state", "agents",
        "enrollment_state IN ('pending', 'enrolled', 'revoked')",
    )
