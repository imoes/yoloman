"""helm_proxy_settings — DB-backed helm chart-pull proxy in SystemSettings

Bossman-wide HTTP(S) proxy for `helm show/pull` (helm runs on the agent host; an
internet OCI registry like oci://registry-1.docker.io/bitnamicharts is unreachable
from a host with no direct egress). Edited in Admin Settings, not via env var —
see api/system_settings.py and services/helm_app.set_helm_proxy.

Idempotent (ADD COLUMN IF NOT EXISTS) because this is applied out-of-band to live
DBs whose alembic chain predates it (see the historical d1e2f3a4b5c6 collision).

Revision ID: b4d1e7c2a9f0
Revises: a2c3d4e5f6b7
"""

from __future__ import annotations

from alembic import op

revision = "b4d1e7c2a9f0"
down_revision = "a2c3d4e5f6b7"
branch_labels = None
depends_on = None

_DEFAULT_NO_PROXY = ".example.internal,localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,.svc,.cluster.local"


def upgrade() -> None:
    op.execute(
        "ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS helm_http_proxy varchar NOT NULL DEFAULT ''"
    )
    op.execute(
        "ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS helm_no_proxy varchar NOT NULL DEFAULT "
        f"'{_DEFAULT_NO_PROXY}'"
    )


def downgrade() -> None:
    op.execute("ALTER TABLE system_settings DROP COLUMN IF EXISTS helm_no_proxy")
    op.execute("ALTER TABLE system_settings DROP COLUMN IF EXISTS helm_http_proxy")
