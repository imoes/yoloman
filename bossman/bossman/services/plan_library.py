"""Plan-library organization: folder placement (ltree) for stored plans/roles.

Each logical plan (prefix+name) can be placed into a directory path
("linux/base") for the plan-library tree; the human `folder` is mirrored into a
sanitized `ltree_path` (like ou_nodes) for future subtree queries. Un-placed
plans live at the root.
"""

from __future__ import annotations

import re
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import DEFAULT_TENANT_ID, PlanPlacement


def sanitize_ltree(folder: str) -> str:
    """Human folder path → ltree label path. "" → "root"; "Linux/Base DB" →
    "Linux.Base_DB" (each segment stripped to [A-Za-z0-9_-])."""
    segs = [s for s in folder.strip("/").split("/") if s.strip()]
    if not segs:
        return "root"
    return ".".join(re.sub(r"[^A-Za-z0-9_-]", "_", s.strip()) for s in segs)


def normalize_folder(folder: str) -> str:
    """Trim + collapse a human folder path ("/linux//base/" → "linux/base")."""
    return "/".join(s.strip() for s in (folder or "").strip("/").split("/") if s.strip())


async def set_placement(session: AsyncSession, prefix: str, name: str, folder: str, tenant: uuid.UUID = DEFAULT_TENANT_ID) -> PlanPlacement:
    folder = normalize_folder(folder)
    ltree = sanitize_ltree(folder)
    existing = await session.scalar(
        select(PlanPlacement).where(PlanPlacement.tenant_id == tenant, PlanPlacement.prefix == prefix, PlanPlacement.name == name)
    )
    if existing is not None:
        existing.folder = folder
        existing.ltree_path = ltree
        return existing
    row = PlanPlacement(tenant_id=tenant, prefix=prefix, name=name, folder=folder, ltree_path=ltree)
    session.add(row)
    return row


async def placement_map(session: AsyncSession, tenant: uuid.UUID = DEFAULT_TENANT_ID) -> dict[tuple[str, str], str]:
    """(prefix, name) → folder for every placed plan."""
    rows = (await session.scalars(select(PlanPlacement).where(PlanPlacement.tenant_id == tenant))).all()
    return {(r.prefix, r.name): r.folder for r in rows}
