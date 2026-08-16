"""Block K4/G — a host's effective desired config, resolved PER KEY across the
GPO levels (host > deepest OU > group), like Windows Group Policy merges per
SETTING, not per file. Each level contributes the keys it configures; a
stronger level overrides only the keys it sets. `key_sources` records the
winning level per key (dot-path for nested formats), so the settings editor can
show where a value is inherited from. Template resources stay whole-file (a
template renders the entire file). Reused by drift + re-sync."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, ConfigPolicy, HostConfigResource, HostGroup, Site
from bossman.services import rule_conditions
from bossman.services.compiler import resolve_host_group_ids, resolve_ou_ancestry, resolve_site_ids


def resource_dict(type_: str | None, path: str, fmt: str | None, sep: str | None, values: dict | None, template: str | None) -> dict[str, Any]:
    res: dict[str, Any] = {"type": type_ or "config", "path": path, "values": values or {}}
    if fmt:
        res["format"] = fmt
    if sep:
        res["separator"] = sep
    if template:
        res["template"] = template
    return res


#: Codecs whose value map is FLAT — a key is one setting, dots in a key are part of the name and
#: never a path into a nested object. Everything else (ini/json/yaml/xml/toml) nests.
#:
#: One definition because the distinction was previously spelled `fmt in (None, "keyvalue")` in
#: three separate places, so adding a codec meant remembering all three. `dirvalue` (a directory
#: with one file per setting, Debian pure-ftpd) is flat in exactly the same way keyvalue is, and
#: `None` means "no codec stated", whose values are treated as a flat map.
FLAT_FORMATS: frozenset[str | None] = frozenset({None, "keyvalue", "dirvalue"})


def is_flat(fmt: str | None) -> bool:
    """True when this codec's values are a flat key→value map (see FLAT_FORMATS)."""
    return fmt in FLAT_FORMATS


def merge_layers(layers: list[tuple[dict, str]], deep: bool) -> tuple[dict, dict[str, str]]:
    """Merge values layers weak→strong. deep=True (ini/yaml/json/xml) merges
    nested dicts per level; keyvalue merges flat (its keys may contain dots).
    Returns (merged values, {key-path: source}). A null value participates —
    it means "managed absent" and can override a weaker level's value."""
    out: dict = {}
    src: dict[str, str] = {}

    def apply(d: dict, s: str, prefix: str, into: dict) -> None:
        for k, v in d.items():
            path = f"{prefix}.{k}" if prefix else str(k)
            if deep and isinstance(v, dict):
                sub = into.get(k)
                if not isinstance(sub, dict):
                    sub = {}
                    into[k] = sub
                apply(v, s, path, sub)
            else:
                into[k] = v
                src[path] = s

    for values, s in layers:
        apply(values or {}, s, "", out)
    return out, src


async def effective_resources(session: AsyncSession, agent: Agent) -> list[dict[str, Any]]:
    """[{path, source, resource, key_sources}] — one per managed path. For
    config-type resources the values are the PER-KEY merge of group < OU(deep)
    < host layers; `source` is the strongest contributing level (badge),
    `key_sources` the winner per key. A template_render resource is whole-file:
    the strongest level's template+values win outright."""
    ancestry = await resolve_ou_ancestry(session, agent.ou_id)  # root → leaf
    depth = {n.id: i for i, n in enumerate(ancestry)}
    ou_paths = {n.id: n.path for n in ancestry}

    # Collect layers per path, weak → strong: group(s), OU shallow→deep, host.
    layers: dict[str, list[tuple[dict[str, Any], str]]] = {}

    # Checkmk rule conditions (host_tags / labels / os-tag / folder / …): a policy
    # with conditions only contributes its layer when they match THIS host. Built
    # once (lazily, only if some policy states conditions); empty conditions = all.
    _ctx: dict[str, rule_conditions.MatchContext] = {}

    async def _keep(pol: ConfigPolicy) -> bool:
        if not getattr(pol, "conditions", None):
            return True
        if "v" not in _ctx:
            from bossman.services.check_assignments import build_match_context

            _ctx["v"] = await build_match_context(session, agent, ancestry)
        return rule_conditions.matches(pol.conditions, _ctx["v"])

    group_ids = await resolve_host_group_ids(session, agent.id)
    if group_ids:
        gnames = dict(
            (await session.execute(select(HostGroup.id, HostGroup.name).where(HostGroup.id.in_(group_ids)))).all()
        )
        gpols = (
            await session.scalars(
                select(ConfigPolicy).where(ConfigPolicy.host_group_id.in_(list(group_ids))).order_by(ConfigPolicy.host_group_id)
            )
        ).all()
        for p in gpols:
            if await _keep(p):
                layers.setdefault(p.path, []).append((_layer(p), "group:" + gnames.get(p.host_group_id, str(p.host_group_id))))

    if depth:
        pols = (await session.scalars(select(ConfigPolicy).where(ConfigPolicy.scope_ou_id.in_(list(depth))))).all()
        for p in sorted(pols, key=lambda p: depth.get(p.scope_ou_id, -1)):  # shallow → deep
            if await _keep(p):
                layers.setdefault(p.path, []).append((_layer(p), "ou:" + ou_paths.get(p.scope_ou_id, str(p.scope_ou_id))))

    # Site layer — stronger than OU, weaker than host (global < group < OU < Site < host).
    site_ids = await resolve_site_ids(session, agent)
    if site_ids:
        snames = dict(
            (await session.execute(select(Site.id, Site.name).where(Site.id.in_(list(site_ids))))).all()
        )
        spols = (
            await session.scalars(
                select(ConfigPolicy).where(ConfigPolicy.site_id.in_(list(site_ids))).order_by(ConfigPolicy.site_id)
            )
        ).all()
        for p in spols:
            if await _keep(p):
                layers.setdefault(p.path, []).append((_layer(p), "site:" + snames.get(p.site_id, str(p.site_id))))

    for row in (await session.scalars(select(HostConfigResource).where(HostConfigResource.agent_id == agent.id))).all():
        layers.setdefault(row.path, []).append((_layer(row), "host"))

    out: list[dict[str, Any]] = []
    for path, lays in layers.items():
        strongest = lays[-1][0]
        source = lays[-1][1]
        if strongest.get("type") == "template_render":
            # Whole-file semantics: the strongest template layer wins outright.
            out.append({"path": path, "source": source, "key_sources": {},
                        "resource": resource_dict("template_render", path, None, None, strongest.get("values"), strongest.get("template"))})
            continue
        fmt = next((l.get("format") for l, _ in reversed(lays) if l.get("format")), None)
        sep = next((l.get("separator") for l, _ in reversed(lays) if l.get("separator")), None)
        deep = not is_flat(fmt)
        merged, key_sources = merge_layers([(l.get("values") or {}, s) for l, s in lays], deep)
        out.append({"path": path, "source": source, "key_sources": key_sources,
                    "resource": resource_dict("config", path, fmt, sep, merged, None)})
    return out


def _layer(row: ConfigPolicy | HostConfigResource) -> dict[str, Any]:
    return {
        "type": row.type, "format": row.config_format, "separator": row.separator,
        "values": row.values or {}, "template": row.template,
    }
