"""Templates CRUD + linking (Zabbix gap-analysis Block K12): a named,
reusable bundle of check rules, live-linked to host groups (editing the
template or its nesting re-materializes every linked group's CheckRule
rows — see services/templates.py) and nestable (a template can include
other templates' rules).

Every query here is explicit (no ORM relationship traversal like
Template.rules) — Block K11 found a real sqlalchemy.exc.MissingGreenlet
from touching a lazy relationship outside an eager-load; this sidesteps
that class of bug entirely, matching services/templates.py's own style.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import Template, TemplateGroup, TemplateLink, TemplateNesting, TemplateRule
from bossman.db.session import get_session
from bossman.services.templates import (
    dematerialize_template_link,
    find_ancestor_template_ids,
    materialize_template,
    materialize_template_link,
)

router = APIRouter()

_COMPARISONS = ("gt", "lt", "ge", "le", "eq", "ne")
_LOGICS = ("AND", "OR")


# ---------------------------------------------------------------------------
# Template groups — simple CRUD, mirrors value_maps.py's shape


class TemplateGroupIn(BaseModel):
    name: str


class TemplateGroupOut(TemplateGroupIn):
    id: UUID

    @classmethod
    def from_model(cls, g: TemplateGroup) -> "TemplateGroupOut":
        return cls(id=g.id, name=g.name)


@router.get("/api/v1/template-groups", response_model=list[TemplateGroupOut])
async def list_template_groups(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[TemplateGroupOut]:
    rows = (await session.scalars(select(TemplateGroup).order_by(TemplateGroup.name))).all()
    return [TemplateGroupOut.from_model(g) for g in rows]


@router.post("/api/v1/template-groups", response_model=TemplateGroupOut)
async def create_template_group(
    body: TemplateGroupIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> TemplateGroupOut:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    group = TemplateGroup(name=body.name)
    session.add(group)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a template group named {body.name!r} already exists") from exc
    return TemplateGroupOut.from_model(group)


@router.delete("/api/v1/template-groups/{group_id}", status_code=204)
async def delete_template_group(
    group_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    group = await session.get(TemplateGroup, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail=f"no such template group {group_id}")
    await session.delete(group)
    await session.commit()


# ---------------------------------------------------------------------------
# Templates


class TemplateRuleIn(BaseModel):
    service_name: str
    metric: str
    comparison: str
    warn_threshold: float | None = None
    crit_threshold: float | None = None
    label_value: str | None = None
    max_attempts: int | None = None
    recovery_threshold: float | None = None
    value_map_id: UUID | None = None
    depends_on_service_name: str | None = None
    extra_conditions: list[dict] | None = None
    condition_logic: str = "AND"


class TemplateRuleOut(TemplateRuleIn):
    id: UUID

    @classmethod
    def from_model(cls, r: TemplateRule) -> "TemplateRuleOut":
        return cls(
            id=r.id, service_name=r.service_name, metric=r.metric, comparison=r.comparison,
            warn_threshold=r.warn_threshold, crit_threshold=r.crit_threshold, label_value=r.label_value,
            max_attempts=r.max_attempts, recovery_threshold=r.recovery_threshold, value_map_id=r.value_map_id,
            depends_on_service_name=r.depends_on_service_name, extra_conditions=r.extra_conditions,
            condition_logic=r.condition_logic,
        )


class TemplateIn(BaseModel):
    name: str
    description: str = ""
    template_group_id: UUID | None = None
    rules: list[TemplateRuleIn] = []
    nested_template_ids: list[UUID] = []


class TemplateOut(BaseModel):
    id: UUID
    name: str
    description: str
    template_group_id: UUID | None
    created_at: datetime
    rules: list[TemplateRuleOut]
    nested_template_ids: list[UUID]


def _validate_rules(rules: list[TemplateRuleIn]) -> None:
    for rule in rules:
        if rule.comparison not in _COMPARISONS:
            raise HTTPException(status_code=422, detail=f"comparison must be one of {_COMPARISONS}")
        if rule.condition_logic not in _LOGICS:
            raise HTTPException(status_code=422, detail=f"condition_logic must be one of {_LOGICS}")
        for cond in rule.extra_conditions or []:
            if "metric" not in cond or "comparison" not in cond:
                raise HTTPException(status_code=422, detail="each extra_conditions entry needs metric and comparison")


async def _build_template_out(session: AsyncSession, template: Template) -> TemplateOut:
    rules = (await session.scalars(select(TemplateRule).where(TemplateRule.template_id == template.id))).all()
    nested_ids = (
        await session.scalars(select(TemplateNesting.child_template_id).where(TemplateNesting.parent_template_id == template.id))
    ).all()
    return TemplateOut(
        id=template.id, name=template.name, description=template.description,
        template_group_id=template.template_group_id, created_at=template.created_at,
        rules=[TemplateRuleOut.from_model(r) for r in rules],
        nested_template_ids=list(nested_ids),
    )


async def _get_template_or_404(session: AsyncSession, template_id: UUID) -> Template:
    template = await session.get(Template, template_id)
    if template is None:
        raise HTTPException(status_code=404, detail=f"no such template {template_id}")
    return template


async def _reject_self_and_missing_nesting(session: AsyncSession, template_id: UUID | None, nested_ids: list[UUID]) -> None:
    if template_id is not None and template_id in nested_ids:
        raise HTTPException(status_code=422, detail="a template cannot nest itself")
    for nid in nested_ids:
        if await session.get(Template, nid) is None:
            raise HTTPException(status_code=422, detail=f"no such template to nest: {nid}")


@router.get("/api/v1/templates", response_model=list[TemplateOut])
async def list_templates(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[TemplateOut]:
    rows = (await session.scalars(select(Template).order_by(Template.name))).all()
    return [await _build_template_out(session, t) for t in rows]


@router.get("/api/v1/templates/{template_id}", response_model=TemplateOut)
async def get_template(
    template_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> TemplateOut:
    template = await _get_template_or_404(session, template_id)
    return await _build_template_out(session, template)


@router.post("/api/v1/templates", response_model=TemplateOut)
async def create_template(
    body: TemplateIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> TemplateOut:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    _validate_rules(body.rules)
    await _reject_self_and_missing_nesting(session, None, body.nested_template_ids)

    # A client-generated id (rather than relying on the server default)
    # means TemplateRule/TemplateNesting rows can be built right away
    # without an early flush() — so a name collision surfaces once, inside
    # the try/except below, instead of crashing uncaught at flush time
    # (a real bug found via testing: the flush this replaced sat outside
    # the try/except entirely).
    template = Template(
        id=uuid4(), name=body.name, description=body.description, template_group_id=body.template_group_id
    )
    session.add(template)
    for rule_in in body.rules:
        session.add(TemplateRule(template_id=template.id, **rule_in.model_dump()))
    for child_id in body.nested_template_ids:
        session.add(TemplateNesting(parent_template_id=template.id, child_template_id=child_id))
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a template named {body.name!r} already exists") from exc
    return await _build_template_out(session, template)


@router.put("/api/v1/templates/{template_id}", response_model=TemplateOut)
async def update_template(
    template_id: UUID,
    body: TemplateIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> TemplateOut:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    _validate_rules(body.rules)
    await _reject_self_and_missing_nesting(session, template_id, body.nested_template_ids)
    template = await _get_template_or_404(session, template_id)

    template.name = body.name
    template.description = body.description
    template.template_group_id = body.template_group_id

    # Replace-all for rules and nesting, matching the check-rule/graph
    # dialogs' "whole form, not a diff" editing shape.
    for old_rule in (await session.scalars(select(TemplateRule).where(TemplateRule.template_id == template_id))).all():
        await session.delete(old_rule)
    for old_nest in (await session.scalars(select(TemplateNesting).where(TemplateNesting.parent_template_id == template_id))).all():
        await session.delete(old_nest)
    await session.flush()
    for rule_in in body.rules:
        session.add(TemplateRule(template_id=template.id, **rule_in.model_dump()))
    for child_id in body.nested_template_ids:
        session.add(TemplateNesting(parent_template_id=template.id, child_template_id=child_id))

    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a template named {body.name!r} already exists") from exc

    # Live-link: cascade the new rule set to every linked group (and every
    # ancestor template's own links, if this one is nested elsewhere).
    await materialize_template(session, template_id)
    await session.commit()
    return await _build_template_out(session, template)


@router.delete("/api/v1/templates/{template_id}", status_code=204)
async def delete_template(
    template_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    # check_rules.template_id/template_rules.template_id/template_nesting/
    # template_links are all ON DELETE CASCADE — deleting the template
    # removes every rule it generated, its own rule/nesting/link rows.
    template = await _get_template_or_404(session, template_id)
    ancestors = await find_ancestor_template_ids(session, template_id)
    await session.delete(template)
    await session.commit()
    # Ancestors that nested this template lose its contributed rules —
    # re-materialize their own links to reflect the smaller effective set.
    for ancestor_id in ancestors:
        await materialize_template(session, ancestor_id)
    if ancestors:
        await session.commit()


# ---------------------------------------------------------------------------
# Template links (host-group linking — the "live" part of "live-linked")


class TemplateLinkIn(BaseModel):
    host_group: str


class TemplateLinkOut(TemplateLinkIn):
    id: UUID
    template_id: UUID

    @classmethod
    def from_model(cls, link: TemplateLink) -> "TemplateLinkOut":
        return cls(id=link.id, template_id=link.template_id, host_group=link.host_group)


@router.get("/api/v1/templates/{template_id}/links", response_model=list[TemplateLinkOut])
async def list_template_links(
    template_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[TemplateLinkOut]:
    await _get_template_or_404(session, template_id)
    rows = (await session.scalars(select(TemplateLink).where(TemplateLink.template_id == template_id))).all()
    return [TemplateLinkOut.from_model(link) for link in rows]


@router.post("/api/v1/templates/{template_id}/links", response_model=TemplateLinkOut)
async def create_template_link(
    template_id: UUID,
    body: TemplateLinkIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> TemplateLinkOut:
    await _get_template_or_404(session, template_id)
    if not body.host_group.strip():
        raise HTTPException(status_code=422, detail="host_group is required")
    link = TemplateLink(template_id=template_id, host_group=body.host_group)
    session.add(link)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=409, detail=f"template {template_id} is already linked to {body.host_group!r}"
        ) from exc
    await materialize_template_link(session, template_id, body.host_group)
    await session.commit()
    return TemplateLinkOut.from_model(link)


@router.delete("/api/v1/templates/{template_id}/links/{link_id}", status_code=204)
async def delete_template_link(
    template_id: UUID,
    link_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> None:
    link = await session.get(TemplateLink, link_id)
    if link is None or link.template_id != template_id:
        raise HTTPException(status_code=404, detail=f"no such link {link_id} on template {template_id}")
    host_group = link.host_group
    await session.delete(link)
    await session.commit()
    await dematerialize_template_link(session, template_id, host_group)
    await session.commit()
