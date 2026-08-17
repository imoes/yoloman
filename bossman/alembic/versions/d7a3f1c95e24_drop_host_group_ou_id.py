"""drop host_groups.ou_id — a group is placeless

A host has exactly one location (agents.ou_id) and arbitrarily many properties. The OU tree carries
the location, its inheritance and its precedence; a group carries a property and is orthogonal to the
tree, which is what lets it say "all webservers, wherever they stand".

`host_groups.ou_id` was a SECOND placement axis, and it caused three problems at once:

  * No resolver ever read it. resolve_ou_ancestry, resolve_host_group_ids, affected_agent_ids and the
    scope/notification contexts all take the OU from agents.ou_id alone — so placing a group in an OU
    changed nothing about which policies reached its members, while looking as though it did.
  * Two placements could contradict: host in /Asia, its group in /Europe. GPO orders by depth along
    ONE path, so two branches have no relative depth and such a collision would be unresolvable.
  * Measured before removal: 0 of 5 groups used the field.

Windows works the same way where it matters: a GPO links to Site/Domain/OU and never to a group;
group membership acts only as Security Filtering on a GPO linked to an OU. The AD group object does
live somewhere in the tree, but purely for delegation, and only because every LDAP object needs a DN.
Our groups are rows with a UUID, so that reason does not apply.

The group's two legitimate ways to influence policy both survive: as a rule SCOPE
(scope_type='group', gpo.LEVEL_GROUP) and as a rule FILTER (rule_conditions' host_groups condition,
which is Security Filtering).

Revision ID: d7a3f1c95e24
Revises: c4f9b2e70a18
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "d7a3f1c95e24"
down_revision = "c4f9b2e70a18"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Dropping the column takes its FK to ou_nodes with it. Guarded so the migration is safe on a
    # database where a previous run already removed it (and on a fresh one built from the model).
    bind = op.get_bind()
    exists = bind.execute(
        sa.text(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name = 'host_groups' AND column_name = 'ou_id'"
        )
    ).first()
    if exists:
        op.drop_column("host_groups", "ou_id")


def downgrade() -> None:
    """Re-adds the column, EMPTY.

    Stated plainly rather than pretended: which OU each group had been filed under is gone with the
    column, and nothing in the schema recorded it elsewhere. A downgrade restores the shape, not the
    data. That is acceptable here only because the field had no effect on any resolver — no policy
    outcome changes by losing it.
    """
    bind = op.get_bind()
    exists = bind.execute(
        sa.text(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name = 'host_groups' AND column_name = 'ou_id'"
        )
    ).first()
    if not exists:
        op.add_column("host_groups", sa.Column("ou_id", sa.dialects.postgresql.UUID(as_uuid=True)))
        op.create_foreign_key(
            "host_groups_ou_id_fkey", "host_groups", "ou_nodes", ["ou_id"], ["id"], ondelete="SET NULL"
        )
