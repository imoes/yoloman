"""drop cert_targets — the standalone certificate inventory is gone

The certificate/expiry inventory (a6b7c8d9e0f1) is superseded by the per-host
`cert` active service check (scripts/translate_active_checks.py, "Service checks"
category), which is configured per host in the UI. The inventory feature (nav
entry, page, REST router, probe loop, model) has been removed; this drops its
now-unused table. The original create migration is left in history so the chain
(audit_log descends from it) stays intact.

Revision ID: c1f0a4b7d2e9
Revises: b4d1e7c2a9f0
"""

from __future__ import annotations

from alembic import op

revision = "c1f0a4b7d2e9"
down_revision = "b4d1e7c2a9f0"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("DROP TABLE IF EXISTS cert_targets")


def downgrade() -> None:
    # Best-effort recreate for a full downgrade path; the feature is gone, so
    # this only restores the empty table shape (matches a6b7c8d9e0f1).
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS cert_targets (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
            name varchar NOT NULL,
            enabled boolean NOT NULL DEFAULT true,
            kind varchar NOT NULL DEFAULT 'tls',
            endpoint varchar NOT NULL DEFAULT '',
            warn_days integer NOT NULL DEFAULT 30,
            crit_days integer NOT NULL DEFAULT 7,
            subject varchar,
            issuer varchar,
            serial varchar,
            not_before timestamptz,
            not_after timestamptz,
            sans jsonb NOT NULL DEFAULT '[]'::jsonb,
            days_left integer,
            status varchar NOT NULL DEFAULT 'unknown',
            last_error varchar,
            last_checked_at timestamptz,
            created_by varchar,
            created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now(),
            CONSTRAINT ck_cert_kind CHECK (kind IN ('tls', 'manual')),
            CONSTRAINT ck_cert_status CHECK (status IN ('ok', 'warning', 'critical', 'expired', 'error', 'unknown'))
        )
        """
    )
