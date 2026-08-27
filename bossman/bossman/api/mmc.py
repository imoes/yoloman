"""THE MANAGEMENT CONSOLE — an MMC/RSAT-shaped view of a managed host, assembled from what the host has.

NAMED `mmc`, NOT `console`, and that is not cosmetic: `console` in this system ALREADY means the interactive
web shell (api/console.py, a PTY relayed over a WebSocket). One word for two things is the equivocation that
costs the most, so this one keeps Microsoft's own abbreviation — an operator who knows what mmc.exe is knows
what this is, and nobody has to guess which console a route means.

WHAT THIS IS AND IS NOT. MMC is a shell: a console tree on the left, a result list with columns per node, and
actions on the selected row. Snap-ins plug into it. This serves exactly that model, from a declarative catalog
(`configs/mmc_snapins.json`), and it is a PRESENTATION — every node's data comes from an endpoint or a module
that already serves the per-host management screens, and every action goes through the one tool-call route.

That rule is what stops it becoming a second product with its own bugs: there is no second data path, so a fix
in `service_facts` shows up in the console and in the Services tab or in neither. What the console adds over
the per-host tabs is what MMC adds over one computer's control panels — one uniform tree of nodes, columns and
actions, over any host in the fleet, including ones whose OS the reader does not know in advance.

AVAILABILITY IS THREE-VALUED. A snap-in is `available`; `unavailable` with a reason naming what is missing (the
host is Linux, the role is not installed, the agent has no such module); or `unknown`, because the host could
not be asked at all. Hiding what is unavailable would leave an operator guessing whether this system can manage
DHCP; calling it broken would be a different untruth. The reason travels with the state, always.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import require_manage_agent
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session
from bossman.services.agent_client import AgentClientError

router = APIRouter()

#: Where the catalog can be. THE CONTAINER PATH IS NOT THE REPO PATH, and computing one from __file__ gets it
#: wrong in exactly one of the two: the repo has bossman/bossman/api/mmc.py under the tree that also holds
#: configs/, the image has /app/bossman/api/mmc.py with configs bind-mounted at /app/configs. So the candidates
#: are listed and the first that exists wins, with the env var the qualify scripts already use taking
#: precedence — one more place guessing at a layout is one more place to be silently wrong.
_CATALOG_CANDIDATES = [
    Path(os.environ.get("AGENTIC_CONFIGS_DIR") or "/nonexistent") / "mmc_snapins.json",
    Path("/app/configs/mmc_snapins.json"),
    Path(__file__).resolve().parents[3] / "configs" / "mmc_snapins.json",
]


def _catalog_path() -> Path:
    for candidate in _CATALOG_CANDIDATES:
        if candidate.is_file():
            return candidate
    # Every path that was tried, because "catalog missing" without them is a bug report nobody can act on.
    raise HTTPException(
        status_code=500,
        detail="snap-in catalog mmc_snapins.json not found; looked in "
               + ", ".join(str(c) for c in _CATALOG_CANDIDATES))


def _catalog() -> dict[str, Any]:
    path = _catalog_path()
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        # The file and the position, because the next person editing this catalog is the one who broke it.
        raise HTTPException(status_code=500,
                            detail=f"snap-in catalog {path} is not valid JSON: {exc}") from exc


async def _agent(session: AsyncSession, agent_id: UUID) -> Agent:
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    return agent


def _requirement_verdict(requirement: dict[str, Any], facts: dict[str, Any],
                         tools: set[str] | None) -> tuple[str, str]:
    """One requirement → (state, reason). state is available | unavailable | unknown.

    `unknown` exists for exactly one case and it matters: a module requirement cannot be judged when the host
    could not be asked for its tool list. Treating that as "unavailable" would tell an operator the host cannot
    do something, when the truth is that we do not know."""
    if "os_family" in requirement:
        wanted = str(requirement["os_family"]).lower()
        actual = str(facts.get("os_family") or "").lower()
        if not actual:
            return "unknown", "this host has not reported its OS family yet"
        return ("available", "") if actual == wanted else (
            "unavailable", f"this snap-in is for {wanted} hosts; this host is {actual}")

    if "module" in requirement:
        name = str(requirement["module"])
        if tools is None:
            return "unknown", "the host could not be asked which modules it has"
        return ("available", "") if name in tools else (
            "unavailable",
            f"the agent on this host has no `{name}` module — it is either an older agent or a platform where "
            f"that module does not exist")

    if "feature" in requirement:
        name = str(requirement["feature"])
        installed = facts.get("windows_features_installed")
        if installed is None:
            return "unknown", "this host has not reported its installed features yet"
        names = {str(f).lower() for f in installed}
        return ("available", "") if name.lower() in names else (
            "unavailable", f"the Windows feature `{name}` is not installed on this host")

    if "endpoint" in requirement:
        # NOT DECIDABLE FROM HERE, and said so rather than guessed. These nodes are served by an AGENT
        # ENDPOINT (its live process table, its observed-state document) rather than by a module, so the tool
        # list cannot answer whether the host serves them — only asking can. `unknown` is exactly that
        # statement, and the node stays clickable: an operator may try, and the result pane reports what came
        # back. Calling it available would promise something we have not checked; calling it unavailable would
        # deny something the host probably does.
        return "unknown", ("this node is served by an agent endpoint rather than a module, so whether this "
                           "host answers it is only known once it is asked — open it and see")

    # An unknown requirement key is REFUSED rather than ignored: a catalog that silently drops a condition
    # would offer a snap-in the host cannot serve, and the failure would arrive as an opaque 502 later.
    return "unavailable", f"the catalog states a requirement this server does not understand: {requirement!r}"


def _titled(entry: dict[str, Any], family: str) -> str:
    """The node's name IN THIS HOST'S VOCABULARY.

    "Event Viewer" is the right title on Windows and the wrong one on Debian, where the same node shows
    journald — and a screen that calls journald the Event Viewer teaches the reader something false about the
    host they are looking at. So a catalog entry may carry `titles: {windows: …, default: …}`; where it does
    not, the single `title` is used, which is correct for the nodes that mean the same thing everywhere
    (Services, Users, Disks)."""
    titles = entry.get("titles")
    if isinstance(titles, dict):
        return titles.get(family) or titles.get("default") or entry.get("title") or ""
    return entry.get("title") or ""


def _resolve(entry: dict[str, Any], facts: dict[str, Any], tools: set[str] | None) -> tuple[str, str]:
    """The weakest verdict over all requirements wins, and its reason travels with it."""
    state, reason = "available", ""
    for requirement in entry.get("requires") or []:
        verdict, why = _requirement_verdict(requirement, facts, tools)
        if verdict == "unavailable":
            return verdict, why
        if verdict == "unknown" and state == "available":
            state, reason = verdict, why
    return state, reason


@router.get("/api/v1/agents/{agent_id}/mmc")
async def get_console_tree(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """The console tree for one host: every snap-in, its nodes, and whether each can serve this host.

    The tool list is fetched ONCE here rather than per node, and its failure is carried rather than raised: a
    host that is down still has a console tree — every snap-in reads `unknown`, which is the honest answer and
    the one that lets the reader tell "cannot" from "cannot tell"."""
    agent = await _agent(session, agent_id)
    facts = agent.facts or {}
    family = str(facts.get("os_family") or "").lower()

    tools: set[str] | None = None
    tools_error = None
    if agent.address:
        client = client_factory(agent, settings)
        try:
            listed = await client.list_tools()
            # A module that IS listed but reports supported:false (a closed write gate, a Linux-only module on
            # Windows) is not usable, so it does not count as present — otherwise the console would offer an
            # action the host refuses, which is the failure mode `hide_when` exists to avoid.
            tools = {t["name"] for t in listed
                     if isinstance(t, dict) and t.get("name") and t.get("supported") is not False}
        except AgentClientError as exc:
            tools_error = str(exc)
    else:
        tools_error = "this agent has no reachable address"

    catalog = _catalog()
    snapins = []
    for entry in catalog.get("snapins") or []:
        state, reason = _resolve(entry, facts, tools)
        nodes = []
        for node in entry.get("nodes") or []:
            node_state, node_reason = _resolve(node, facts, tools)
            # A node cannot be more available than its snap-in — the snap-in's verdict is the floor.
            if state != "available" and node_state == "available":
                node_state, node_reason = state, reason
            nodes.append({
                "id": node.get("id"),
                "title": _titled(node, family),
                "state": node_state,
                "reason": node_reason,
                "columns": node.get("columns") or [],
                "actions": [a for a in (node.get("actions") or [])],
            })
        snapins.append({
            "id": entry.get("id"),
            "title": _titled(entry, family),
            "icon": entry.get("icon"),
            "description": entry.get("description"),
            # The MMC name is shown only where it means something. On a Debian host "eventvwr.msc" would be a
            # label for a program that is not there.
            "mmc_equivalent": entry.get("mmc_equivalent") if family == "windows" else None,
            "state": state,
            "reason": reason,
            "nodes": nodes,
        })

    return {
        "agent_id": str(agent.id),
        "host": agent.name,
        "os_family": facts.get("os_family"),
        "catalog_version": catalog.get("version"),
        # WHY A VERDICT IS "unknown", said once at the top instead of repeated per snap-in.
        "tools_error": tools_error,
        "snapins": snapins,
    }


def _dig(payload: Any, path: str) -> Any:
    """Follow a dotted path into a response. An empty path means the payload IS the value."""
    if not path:
        return payload
    current = payload
    for part in path.split("."):
        if isinstance(current, dict):
            current = current.get(part)
        else:
            return None
    return current


def _flatten(rows: list[dict], child_key: str) -> list[dict]:
    """Depth-first flatten of a parent/child tree into rows carrying `_depth`.

    The result pane is a list, and MMC's own Disk Management shows disks with their volumes indented under
    them. Keeping the nesting as a depth column rather than as nested arrays means ONE renderer for every
    node — a tree-shaped result pane for one snap-in and a flat one for the rest would be two tables again."""
    out: list[dict] = []

    def walk(items: list[dict], depth: int) -> None:
        for item in items or []:
            if not isinstance(item, dict):
                continue
            children = item.get(child_key) or []
            row = {k: v for k, v in item.items() if k != child_key}
            row["_depth"] = depth
            out.append(row)
            walk(children if isinstance(children, list) else [], depth + 1)

    walk(rows, 0)
    return out


@router.get("/api/v1/agents/{agent_id}/mmc/{snapin_id}/{node_id}")
async def get_console_node(
    agent_id: UUID,
    snapin_id: str,
    node_id: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """One node's result pane: its columns (from the catalog) and its rows (from the host).

    An `endpoint` source is called IN-PROCESS through the app's own router, not over HTTP to ourselves: the
    caller's credentials are already established, and a self-request would need a second set of them plus a
    round trip. A `tool` source goes through the agent client with the catalog's fixed parameters — the
    catalog never receives parameters from the request, so a node cannot be turned into an arbitrary module
    call by whoever crafts the URL."""
    agent = await _agent(session, agent_id)
    catalog = _catalog()

    snapin = next((s for s in catalog.get("snapins") or [] if s.get("id") == snapin_id), None)
    if snapin is None:
        raise HTTPException(status_code=404, detail=f"no such snap-in {snapin_id!r}")
    node = next((n for n in snapin.get("nodes") or [] if n.get("id") == node_id), None)
    if node is None:
        raise HTTPException(status_code=404,
                            detail=f"snap-in {snapin_id!r} has no node {node_id!r}")

    facts = agent.facts or {}
    source = node.get("source") or {}
    rows: list[dict] = []
    error: str | None = None

    try:
        if source.get("kind") == "tool":
            if not agent.address:
                raise AgentClientError(f"agent {agent.name!r} has no reachable address")
            client = client_factory(agent, settings)
            result = await client.call_tool(source["tool"], dict(source.get("params") or {}))
            data = (result or {}).get("data") if isinstance(result, dict) else None
            candidate = _dig(data, source.get("rows") or "")
            rows = candidate if isinstance(candidate, list) else []
        elif source.get("kind") == "endpoint":
            payload = await _call_own_endpoint(request, source["path"].format(agent_id=agent.id))
            candidate = _dig(payload, source.get("rows") or "")
            rows = candidate if isinstance(candidate, list) else []
        else:
            raise HTTPException(status_code=500,
                                detail=f"node {snapin_id}/{node_id}: source kind "
                                       f"{source.get('kind')!r} is not one of tool, endpoint")
    except AgentClientError as exc:
        # THE NODE STILL ANSWERS, with its columns and the reason it has no rows. A 502 here would leave the
        # console unable to say anything about a host that is merely unreachable, and "empty list" would be a
        # lie about a host that has services it cannot report right now.
        error = str(exc)

    if source.get("flatten_children") and rows:
        rows = _flatten(rows, source["flatten_children"])

    sort = node.get("sort")
    if sort and rows:
        key = sort.lstrip("-")
        descending = sort.startswith("-")
        # Sorted here rather than in the UI so every consumer sees one order, and defensively: a row missing
        # the key sorts last instead of raising.
        rows.sort(key=lambda r: (r.get(key) is None, _sortable(r.get(key))), reverse=descending)

    return {
        "agent_id": str(agent.id),
        "host": agent.name,
        "os_family": facts.get("os_family"),
        "snapin": snapin_id,
        "node": node_id,
        "title": _titled(node, str(facts.get("os_family") or "").lower()),
        "columns": node.get("columns") or [],
        "actions": node.get("actions") or [],
        "rows": rows,
        "count": len(rows),
        "error": error,
    }


def _sortable(value: Any) -> Any:
    """A sort key that does not raise on mixed types: numbers stay numbers, everything else compares as its
    lower-cased text. A result pane must not 500 because one row has a null where others have a string."""
    if isinstance(value, bool):
        return (0, str(value))
    if isinstance(value, (int, float)):
        return (0, value)
    return (1, str(value or "").lower())


async def _call_own_endpoint(request: Request, path: str) -> Any:
    """Call one of this app's own GET routes in-process, with the caller's own credentials.

    THE CALL ITSELF IS THE CHECK. An earlier version validated the path against `app.routes` first, by
    matching each route's compiled regex — and it refused a path that the running app serves perfectly
    (`/api/v1/agents/{id}/service-units`), because the route list reachable that way is not the one answering
    requests. Framework internals are the wrong thing to assert against: the honest test of "does this route
    exist" is to ask for it and read the status.

    Re-entered through httpx's ASGI transport rather than over a socket: no second TLS handshake, and the REAL
    dependency chain runs — session, settings, identity — so an internal call is authorised exactly like an
    external one instead of quietly running with more rights than whoever asked. Only the auth headers are
    forwarded, nothing else of the caller's request.
    """
    import httpx
    from urllib.parse import parse_qsl, urlsplit

    split = urlsplit(path)
    headers = {k: v for k, v in request.headers.items()
               if k.lower() in ("authorization", "cookie", "x-api-key")}
    transport = httpx.ASGITransport(app=request.app)
    async with httpx.AsyncClient(transport=transport, base_url="http://console.internal") as client:
        response = await client.get(split.path, params=dict(parse_qsl(split.query)), headers=headers)

    if response.status_code == 404:
        # A 404 here is not "the host has nothing": it is the CATALOG naming a route this server does not
        # serve. Said as that, because an empty result pane would look like an answer.
        raise HTTPException(
            status_code=500,
            detail=f"the snap-in catalog points at {split.path!r}, which this server answered with 404 — the "
                   f"catalog and the API have drifted apart")
    if response.status_code != 200:
        # Raised as an AgentClientError so the node still answers with its columns and this reason, rather
        # than 502-ing the whole console for one node that could not be filled.
        raise AgentClientError(f"{split.path} answered {response.status_code}: {response.text[:400]}")
    return response.json()
