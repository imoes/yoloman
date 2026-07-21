"""The Checkmk-style fleet-search query language + compiler.

A small boolean mini-language over the fleet's hosts and service-checks:

    disk                         bare word → substring over host/service names
    s:disk st:CRIT               field-scoped terms, whitespace = AND
    st:CRIT OR st:WARN           OR / | for alternatives
    s:postgres !host:db-old      ! (or the word NOT) negates a term
    (st:CRIT OR st:WARN) s:disk  parentheses group
    s:"backup job"               quotes for values with spaces

Fields: h/host, hg/group, s/service, st/state, crit/criticality, site/location,
ou, tag, metric. A bare word matches across host name/dns + service name. Values
are matched with ILIKE substring (never raw regex → no injection). The parser
produces a small AST that `compile_hosts` / `compile_services` translate into a
SQLAlchemy boolean expression; the same parse feeds the dropdown preview and the
full result views so search and manual filtering stay identical.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

import uuid

from sqlalchemy import and_, case, func, not_, or_, select, text
from sqlalchemy.sql.elements import ColumnElement

from bossman.db.models import Agent, OUNode, Service

# ── AST ──────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Term:
    field: str | None  # normalized field name, or None for a bare word
    value: str


@dataclass(frozen=True)
class Not:
    child: "Node"


@dataclass(frozen=True)
class And:
    children: tuple["Node", ...]


@dataclass(frozen=True)
class Or:
    children: tuple["Node", ...]


Node = Term | Not | And | Or

# Field aliases → canonical field name.
_FIELD_ALIASES = {
    "h": "host", "host": "host",
    "hg": "group", "group": "group", "hostgroup": "group",
    "s": "service", "service": "service", "svc": "service",
    "st": "state", "state": "state",
    "crit": "criticality", "criticality": "criticality",
    "site": "site", "location": "site",
    "ou": "ou",
    "tag": "tag",
    "metric": "metric",
}
_KEYWORDS = {"and": "AND", "or": "OR", "not": "NOT"}

# ── tokenizer ──────────────────────────────────────────────────────────────


def _tokenize(q: str) -> list[tuple]:
    """Split into ('LPAREN'|'RPAREN'|'AND'|'OR'|'NOT') markers and
    ('TERM', field|None, value). Quotes protect spaces; `!` is a NOT prefix."""
    tokens: list[tuple] = []
    i, n = 0, len(q)
    while i < n:
        c = q[i]
        if c.isspace():
            i += 1
            continue
        if c == "(":
            tokens.append(("LPAREN",))
            i += 1
            continue
        if c == ")":
            tokens.append(("RPAREN",))
            i += 1
            continue
        if c == "|":
            tokens.append(("OR",))
            i += 1
            continue
        if c == "!":
            tokens.append(("NOT",))
            i += 1
            continue
        # Read one word (a bare value or field:value), honoring quotes.
        buf = []
        while i < n and not q[i].isspace() and q[i] not in "()":
            if q[i] == '"':
                i += 1
                while i < n and q[i] != '"':
                    buf.append(q[i])
                    i += 1
                i += 1  # skip closing quote (or EOS)
                continue
            if q[i] == "!" and not buf:
                break  # leading ! already handled above; defensive
            buf.append(q[i])
            i += 1
        word = "".join(buf)
        if not word:
            continue
        kw = _KEYWORDS.get(word.lower())
        if kw:
            tokens.append((kw,))
            continue
        field, sep, value = word.partition(":")
        if sep and field.lower() in _FIELD_ALIASES:
            tokens.append(("TERM", _FIELD_ALIASES[field.lower()], value))
        else:
            tokens.append(("TERM", None, word))
    return tokens


# ── recursive-descent parser (precedence: NOT > AND > OR) ────────────────


class _Parser:
    def __init__(self, tokens: list[tuple]):
        self.toks = tokens
        self.pos = 0

    def _peek(self):
        return self.toks[self.pos] if self.pos < len(self.toks) else None

    def _next(self):
        t = self.toks[self.pos]
        self.pos += 1
        return t

    def parse(self) -> Node | None:
        if not self.toks:
            return None
        node = self._parse_or()
        return node

    def _parse_or(self) -> Node:
        parts = [self._parse_and()]
        while self._peek() and self._peek()[0] == "OR":
            self._next()
            parts.append(self._parse_and())
        return parts[0] if len(parts) == 1 else Or(tuple(parts))

    def _parse_and(self) -> Node:
        parts = [self._parse_unary()]
        while True:
            t = self._peek()
            if t is None or t[0] in ("OR", "RPAREN"):
                break
            if t[0] == "AND":
                self._next()  # explicit AND
            # else: implicit AND — adjacency
            parts.append(self._parse_unary())
        return parts[0] if len(parts) == 1 else And(tuple(parts))

    def _parse_unary(self) -> Node:
        t = self._peek()
        if t and t[0] == "NOT":
            self._next()
            return Not(self._parse_unary())
        return self._parse_atom()

    def _parse_atom(self) -> Node:
        t = self._next()
        if t[0] == "LPAREN":
            node = self._parse_or()
            if self._peek() and self._peek()[0] == "RPAREN":
                self._next()
            return node
        if t[0] == "TERM":
            return Term(t[1], t[2])
        # A stray operator token where an atom was expected → treat as empty.
        return Term(None, "")


def parse_query(q: str) -> Node | None:
    """Parse a raw query string into an AST (None for an empty query)."""
    return _Parser(_tokenize(q or "")).parse()


# ── compilation to SQLAlchemy ────────────────────────────────────────────


def _like(value: str) -> str:
    # Escape ILIKE wildcards in user input, then substring-wrap.
    v = value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{v}%"


def _groups_match(value: str) -> ColumnElement:
    # Agent.groups is a text[]; match any element containing the value.
    return func.array_to_string(Agent.groups, " ").ilike(_like(value))


def _ou_match(value: str) -> ColumnElement:
    return Agent.ou_id.in_(select(OUNode.id).where(OUNode.path.ilike(_like(value))))


def _tag_match(value: str) -> ColumnElement:
    name, _, val = value.partition(":")
    cond = Agent.tags.has_key(name)  # noqa: W601 — SQLAlchemy JSONB has_key
    if val:
        cond = and_(cond, Agent.tags[name].astext == val)
    return cond


def _service_exists(cond: ColumnElement) -> ColumnElement:
    """A host matches a service-level term if it has ≥1 service satisfying it."""
    return Agent.id.in_(select(Service.agent_id).where(cond))


def _host_term(field: str | None, value: str) -> ColumnElement:
    if field == "host":
        return or_(Agent.name.ilike(_like(value)), Agent.address.ilike(_like(value)))
    if field == "group":
        return _groups_match(value)
    if field == "criticality":
        return Agent.criticality == value.lower()
    if field == "site":
        return Agent.site.ilike(_like(value))
    if field == "ou":
        return _ou_match(value)
    if field == "tag":
        return _tag_match(value)
    if field == "service":
        return _service_exists(Service.name.ilike(_like(value)))
    if field == "metric":
        return _service_exists(Service.metric.ilike(_like(value)))
    if field == "state":
        return _service_exists(Service.state == value.upper())
    # bare word → host name/address
    return or_(Agent.name.ilike(_like(value)), Agent.address.ilike(_like(value)))


def _service_term(field: str | None, value: str) -> ColumnElement:
    if field == "service":
        return Service.name.ilike(_like(value))
    if field == "metric":
        return Service.metric.ilike(_like(value))
    if field == "state":
        return Service.state == value.upper()
    if field == "host":
        return or_(Agent.name.ilike(_like(value)), Agent.address.ilike(_like(value)))
    if field == "group":
        return _groups_match(value)
    if field == "criticality":
        return Agent.criticality == value.lower()
    if field == "site":
        return Agent.site.ilike(_like(value))
    if field == "ou":
        return _ou_match(value)
    if field == "tag":
        return _tag_match(value)
    # bare word → service or host name
    return or_(Service.name.ilike(_like(value)), Agent.name.ilike(_like(value)))


def _compile(node: Node, term_fn: Callable[[str | None, str], ColumnElement]) -> ColumnElement | None:
    if node is None:
        return None
    if isinstance(node, Term):
        if node.value == "":
            return None
        return term_fn(node.field, node.value)
    if isinstance(node, Not):
        inner = _compile(node.child, term_fn)
        return not_(inner) if inner is not None else None
    if isinstance(node, And):
        parts = [p for p in (_compile(c, term_fn) for c in node.children) if p is not None]
        return and_(*parts) if parts else None
    if isinstance(node, Or):
        parts = [p for p in (_compile(c, term_fn) for c in node.children) if p is not None]
        return or_(*parts) if parts else None
    return None


def compile_hosts(node: Node | None) -> ColumnElement | None:
    """Boolean predicate over Agent (service-level terms become EXISTS)."""
    return _compile(node, _host_term) if node is not None else None


def compile_services(node: Node | None) -> ColumnElement | None:
    """Boolean predicate over a Service⋈Agent join."""
    return _compile(node, _service_term) if node is not None else None


# ── group (flat Agent.groups) predicate ─────────────────────────────────

_FALSE = func.coalesce(None, None).isnot(None)  # a constant-false ColumnElement


def _group_term(field: str | None, value: str) -> ColumnElement:
    # Only host-name-free, group-relevant terms select a group; everything
    # else (st:/service:/metric:) has no meaning for a group entity → false.
    if field in (None, "group"):
        return func.array_to_string(Agent.groups, " ").ilike(_like(value))
    return _FALSE


def compile_groups(node: Node | None) -> ColumnElement | None:
    return _compile(node, _group_term) if node is not None else None


# ── executors ─────────────────────────────────────────────────────────────


def _not_infra() -> ColumnElement:
    # Hide the co-located SNMP/SSH poller (agent_metadata.role == "poller").
    return Agent.agent_metadata["role"].astext.is_distinct_from("poller")


async def search_hosts(session, node: Node | None, *, limit: int = 50, offset: int = 0) -> list[Agent]:
    stmt = select(Agent).where(_not_infra())
    pred = compile_hosts(node)
    if pred is not None:
        stmt = stmt.where(pred)
    stmt = stmt.order_by(Agent.name).limit(limit).offset(offset)
    return list((await session.execute(stmt)).scalars().all())


async def count_hosts(session, node: Node | None) -> int:
    stmt = select(func.count()).select_from(Agent).where(_not_infra())
    pred = compile_hosts(node)
    if pred is not None:
        stmt = stmt.where(pred)
    return int((await session.execute(stmt)).scalar_one())


async def search_services(session, node: Node | None, *, limit: int = 50, offset: int = 0) -> list[tuple[Service, Agent]]:
    stmt = (
        select(Service, Agent)
        .join(Agent, Agent.id == Service.agent_id)
        .where(_not_infra())
    )
    pred = compile_services(node)
    if pred is not None:
        stmt = stmt.where(pred)
    stmt = stmt.order_by(Service.state.desc(), Agent.name, Service.name).limit(limit).offset(offset)
    return [(row[0], row[1]) for row in (await session.execute(stmt)).all()]


async def count_services(session, node: Node | None) -> int:
    stmt = select(func.count()).select_from(Service).join(Agent, Agent.id == Service.agent_id).where(_not_infra())
    pred = compile_services(node)
    if pred is not None:
        stmt = stmt.where(pred)
    return int((await session.execute(stmt)).scalar_one())


async def search_groups(session, node: Node | None, *, limit: int = 50) -> list[str]:
    """Distinct flat group names (Agent.groups) matching the query — the same
    values the hg:/group: filter targets, so the dropdown stays consistent."""
    grp = func.unnest(Agent.groups).label("g")
    sub = select(grp).where(_not_infra()).subquery()
    stmt = select(sub.c.g).distinct().order_by(sub.c.g).limit(limit)
    pred = compile_groups(node)
    if pred is not None:
        # Re-apply the group predicate on the base table before unnest.
        base = select(func.unnest(Agent.groups).label("g")).where(_not_infra(), pred).subquery()
        stmt = select(base.c.g).distinct().order_by(base.c.g).limit(limit)
    return [r for (r,) in (await session.execute(stmt)).all() if r]


_SEVERITY = case(
    (Service.state == "CRIT", 3),
    (Service.state == "WARN", 2),
    (Service.state == "UNKNOWN", 1),
    else_=0,
)
_SEV_TO_STATE = {3: "CRIT", 2: "WARN", 1: "UNKNOWN", 0: "OK"}


async def worst_states(session, agent_ids: list[uuid.UUID]) -> dict[uuid.UUID, str]:
    """The worst (highest-severity) service state per agent — the host-row
    state rollup for a hosts result list. Agents with no services are absent."""
    if not agent_ids:
        return {}
    stmt = (
        select(Service.agent_id, func.max(_SEVERITY))
        .where(Service.agent_id.in_(agent_ids))
        .group_by(Service.agent_id)
    )
    return {aid: _SEV_TO_STATE.get(int(sev), "OK") for aid, sev in (await session.execute(stmt)).all()}


async def distinct_sites(session) -> list[str]:
    """Every distinct non-null site across the fleet (for site: autocomplete)."""
    stmt = (
        select(Agent.site).distinct()
        .where(Agent.site.isnot(None), _not_infra())
        .order_by(Agent.site)
    )
    return [s for (s,) in (await session.execute(stmt)).all() if s]


async def distinct_tags(session) -> dict[str, list[str]]:
    """Every distinct tag key → its distinct non-empty values across the fleet
    (for tag: autocomplete). name-only tags (empty value) appear as a key with
    an empty value list."""
    rows = (await session.execute(text(
        "SELECT DISTINCT je.key, je.value FROM agents a, LATERAL jsonb_each_text(a.tags) je "
        "WHERE (a.agent_metadata->>'role') IS DISTINCT FROM 'poller'"
    ))).all()
    out: dict[str, list[str]] = {}
    for key, value in rows:
        vals = out.setdefault(key, [])
        if value and value not in vals:
            vals.append(value)
    for vals in out.values():
        vals.sort()
    return out
