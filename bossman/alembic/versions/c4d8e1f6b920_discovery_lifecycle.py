"""persist what discovery found, with Checkmk's lifecycle — autochecks in Postgres

Our discovery was stateless: run_check_discovery returned in-memory proposals and only
the ACCEPTED ones survived, as check_assignments rows. Two consequences, both real:

  * A service that disappeared from a host was never noticed. `vanished` did not occur
    once in the application code.
  * check_assignments held "what exists" AND "how it is monitored" in the same row —
    the one split Checkmk never makes.

Checkmk keeps the discovery result as autochecks:

    AutocheckEntry(check_plugin_name, item, parameters, service_labels)
        id()         = (check_plugin_name, item)
        comparator() = (parameters, service_labels)

and every run compares the persisted set against the fresh one via QualifiedDiscovery
(cmk/checkengine/discovery/types.py), classifying new / unchanged / changed / vanished.
This revision creates the Postgres home for that set, plus host labels — which Checkhk
discovers at section level and runs through the SAME classification, so they belong to
the same step rather than a later one.

DELIBERATE DEVIATIONS (the project rule is to document each one):
  * autochecks live in a per-host FILE in Checkmk. Here: a table. PostgreSQL is the
    single source of truth; file-based state is explicitly out.
  * Checkmk's `Item` is `str | None`. Here: item NOT NULL DEFAULT ''. A NULL does not
    deduplicate in a Postgres UNIQUE, so a single-service check could be inserted
    twice — and the code already uses item="" throughout.
  * `state` carries the DISCOVERY lifecycle, deliberately separate from services.state
    (the monitoring state). Nothing about OK/WARN/CRIT belongs here.

Nothing is migrated INTO these tables here: existing autodiscovered assignments keep
working unchanged, and the first discovery run per host fills the table. Switching the
execution path over to it is a separate, explicitly deferred step.

Revision ID: c4d8e1f6b920
Revises: b5e2d7a91c36
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "c4d8e1f6b920"
down_revision = "b5e2d7a91c36"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "discovered_services",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("check_name", sa.String(), nullable=False),
        sa.Column("item", sa.String(), nullable=False, server_default=""),
        sa.Column("parameters", JSONB, nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("service_labels", JSONB, nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("state", sa.String(), nullable=False, server_default="undecided"),
        sa.Column("first_seen_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("last_changed_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint(
            "state IN ('undecided', 'monitored', 'vanished', 'ignored')",
            name="ck_discovered_services_state",
        ),
        # The service identity, enforced by the database — Checkmk's ServiceID.
        sa.UniqueConstraint("agent_id", "check_name", "item", name="uq_discovered_services_identity"),
    )
    # The discovery page's query is "everything on this host, grouped by state".
    op.create_index("idx_discovered_services_agent_state", "discovered_services", ["agent_id", "state"])
    op.create_index("idx_discovered_services_check", "discovered_services", ["check_name"])

    op.create_table(
        "host_labels",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("key", sa.String(), nullable=False),
        sa.Column("value", sa.String(), nullable=False),
        # source keeps a discovery run from ever overwriting a hand-set label.
        sa.Column("source", sa.String(), nullable=False, server_default="discovered"),
        sa.Column("first_seen_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("source IN ('discovered', 'explicit', 'ruleset')", name="ck_host_labels_source"),
        sa.UniqueConstraint("agent_id", "key", name="uq_host_labels_identity"),
    )
    op.create_index("idx_host_labels_agent", "host_labels", ["agent_id"])
    # Rule conditions will match on key:value pairs (Batch 2), hence this index now.
    op.create_index("idx_host_labels_kv", "host_labels", ["key", "value"])


def downgrade() -> None:
    op.drop_index("idx_host_labels_kv", table_name="host_labels")
    op.drop_index("idx_host_labels_agent", table_name="host_labels")
    op.drop_table("host_labels")
    op.drop_index("idx_discovered_services_check", table_name="discovered_services")
    op.drop_index("idx_discovered_services_agent_state", table_name="discovered_services")
    op.drop_table("discovered_services")
