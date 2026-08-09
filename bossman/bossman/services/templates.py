"""Template materialization (Zabbix gap-analysis Block K12): the "live
link" half of Templates — turning a Template's bundled TemplateRule rows
(plus everything nested templates contribute) into real, scoped CheckRule
rows for each host group it's linked to, and keeping them in sync
whenever the template, its nesting, or a link changes.

Framework-free (no FastAPI import), like services/monitoring.py, so it's
reachable from the REST API and tests without duplicating logic. Every
function here uses explicit select() queries rather than ORM relationship
traversal (Template.rules etc.) on purpose — Block K11 found a real
sqlalchemy.exc.MissingGreenlet from touching a lazy relationship outside
an eager-load; explicit queries sidestep that class of bug entirely.
"""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import CheckRule, TemplateLink, TemplateNesting, TemplateRule

_RULE_FIELDS = (
    "service_name", "metric", "comparison", "warn_threshold", "crit_threshold",
    "label_value", "max_attempts", "recovery_threshold", "value_map_id",
    "depends_on_service_name", "extra_conditions", "condition_logic",
)


async def collect_effective_rules(
    session: AsyncSession, template_id: UUID, _seen: set[UUID] | None = None
) -> list[TemplateRule]:
    """Every TemplateRule owned by this template, plus every rule
    contributed by templates it (transitively) nests — cycle-safe."""
    seen = _seen if _seen is not None else set()
    if template_id in seen:
        return []
    seen.add(template_id)

    own = list((await session.scalars(select(TemplateRule).where(TemplateRule.template_id == template_id))).all())
    child_ids = (
        await session.scalars(select(TemplateNesting.child_template_id).where(TemplateNesting.parent_template_id == template_id))
    ).all()
    for child_id in child_ids:
        own += await collect_effective_rules(session, child_id, seen)
    return own


async def find_ancestor_template_ids(
    session: AsyncSession, template_id: UUID, _seen: set[UUID] | None = None
) -> set[UUID]:
    """Every template that (transitively) nests this one — so a change to
    a nested (child) template's rules can cascade re-materialization up to
    every parent template that includes it, not just the child's own
    direct links."""
    seen = _seen if _seen is not None else set()
    parent_ids = (
        await session.scalars(select(TemplateNesting.parent_template_id).where(TemplateNesting.child_template_id == template_id))
    ).all()
    result: set[UUID] = set()
    for parent_id in parent_ids:
        if parent_id in seen:
            continue
        seen.add(parent_id)
        result.add(parent_id)
        result |= await find_ancestor_template_ids(session, parent_id, seen)
    return result


async def materialize_template_link(session: AsyncSession, template_id: UUID, host_group: str) -> None:
    """(Re-)generates this (template, host_group) link's CheckRule rows
    from the template's current effective rule set (own + nested),
    upserting by source_template_rule_id so re-materialization updates
    existing rows in place rather than duplicating them, and removes any
    materialized row whose TemplateRule no longer exists in the effective
    set (a rule was deleted from the template, or a nested template was
    unnested). Does not commit; the caller owns the transaction boundary."""
    effective = await collect_effective_rules(session, template_id)
    effective_ids = {r.id for r in effective}

    existing = (
        await session.scalars(
            select(CheckRule).where(CheckRule.template_id == template_id, CheckRule.scope_value == host_group)
        )
    ).all()
    for row in existing:
        if row.source_template_rule_id not in effective_ids:
            await session.delete(row)
    await session.flush()

    by_source = {row.source_template_rule_id: row for row in existing if row.source_template_rule_id in effective_ids}
    for rule in effective:
        target = by_source.get(rule.id)
        if target is None:
            target = CheckRule(
                template_id=template_id, source_template_rule_id=rule.id,
                scope_type="group", scope_value=host_group, enabled=True,
                service_name=rule.service_name, metric=rule.metric, comparison=rule.comparison,
            )
            session.add(target)
        for field in _RULE_FIELDS:
            setattr(target, field, getattr(rule, field))
    await session.flush()


async def dematerialize_template_link(session: AsyncSession, template_id: UUID, host_group: str) -> None:
    """Removes every CheckRule this (template, host_group) link generated
    — called when a TemplateLink is deleted (unlinking a template from a
    host group)."""
    existing = (
        await session.scalars(
            select(CheckRule).where(CheckRule.template_id == template_id, CheckRule.scope_value == host_group)
        )
    ).all()
    for row in existing:
        await session.delete(row)
    await session.flush()


async def materialize_template(session: AsyncSession, template_id: UUID) -> None:
    """Re-materializes every direct link of this template, and cascades to
    every ancestor template's own links too — since an ancestor's
    effective rule set includes this template's rules if it nests it.
    Call after any TemplateRule/nesting change; a link create/delete only
    needs materialize_template_link/dematerialize_template_link for
    itself."""
    template_ids = {template_id} | await find_ancestor_template_ids(session, template_id)
    for tid in template_ids:
        links = (await session.scalars(select(TemplateLink).where(TemplateLink.template_id == tid))).all()
        for link in links:
            await materialize_template_link(session, tid, link.host_group)
