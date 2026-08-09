"""strip the legacy `ansible.builtin.` module prefix from stored plan bodies

yolo-man is not Ansible: a step names its module with the bare native name.
Older AI-authored/imported plans persisted `ansible.builtin.<mod>` step keys
(the chat prompt used to teach that form). The loader stripped the prefix at
run time, but it leaked into the plan library/editor. This rewrites every
stored plan version's canonical body to the bare module name.

Revision ID: f6a7b8c9d0e1
Revises: e5f6a7b8c9d0
"""

from __future__ import annotations

import json

import sqlalchemy as sa
from alembic import op

revision = "f6a7b8c9d0e1"
down_revision = "e5f6a7b8c9d0"
branch_labels = None
depends_on = None

_PREFIX = "ansible.builtin."


def _strip(node: object) -> bool:
    """Rewrite `ansible.builtin.<mod>` step keys to `<mod>` in place. Returns
    True if anything changed."""
    changed = False
    if not isinstance(node, dict):
        return False
    chunks = node.get("chunks")
    if isinstance(chunks, list):
        for chunk in chunks:
            changed |= _strip(chunk)
    steps = list(node.get("steps") or []) if isinstance(node.get("steps"), list) else []
    handler = node.get("final_handler")
    if isinstance(handler, dict):
        steps.append(handler)
    for step in steps:
        if not isinstance(step, dict):
            continue
        for key in [k for k in step if isinstance(k, str) and k.startswith(_PREFIX)]:
            step[key[len(_PREFIX):]] = step.pop(key)
            changed = True
    return changed


def upgrade() -> None:
    bind = op.get_bind()
    rows = bind.execute(sa.text("SELECT id, body FROM plans")).fetchall()
    for row in rows:
        body = row.body
        if isinstance(body, str):
            body = json.loads(body)
        if _strip(body):
            bind.execute(
                sa.text("UPDATE plans SET body = CAST(:body AS jsonb) WHERE id = :id"),
                {"body": json.dumps(body), "id": row.id},
            )


def downgrade() -> None:
    # One-way normalization; the bare module name is the canonical form.
    pass
