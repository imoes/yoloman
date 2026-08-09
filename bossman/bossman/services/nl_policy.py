"""Natural-language → config-policy proposal.

Turn "set the NTP server to 10.0.0.1 on all Debian web servers in Munich" into a
STRUCTURED, reviewable config-policy proposal — never applied automatically. The
model is grounded with the fleet's real scopes (OU paths, groups, sites) and
condition vocabulary (tag/fact/variable keys) so it picks targets that exist, and
the proposal is run through whatif to show its blast radius before anyone commits.
"""

from __future__ import annotations

import json
import re
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import Agent, HostGroup, HostLabel, OUNode, ScopeVars, Site
from bossman.services.chat_backend import ChatBackendError, chat_backend_for
from bossman.services.rule_conditions import flatten_facts
from bossman.services.whatif import whatif_scope

_SYSTEM = """You translate a plain-language request into ONE config-policy proposal for a fleet
manager. Reply with a SINGLE JSON object and nothing else (no prose, no code fences):

{
  "path": "/etc/ntp.conf",              // absolute config file path
  "format": "keyvalue",                  // keyvalue | ini | json | yaml
  "values": {"server": "10.0.0.1"},     // desired key→value(s); null value = enforce absent
  "scope": {"type": "ou", "name": "/Mue-0"},   // type: ou|group|site|global ; name matches the lists below
  "conditions": {},                      // optional Checkmk conditions (see below), {} = none
  "explanation": "one sentence on what this does and where"
}

conditions grammar (all optional, ANDed): host_tags {group: "val" | {"$ne"|"$or"|"$nor": ...}},
host_facts {dotted.key: ...} (Ansible facts, e.g. os.family), host_vars {name: ...} (variables),
host_label_groups / service_label_groups [["and",[["and","k:v"],...]]], host_name / service_description
["name" | {"$regex":"^re"}] (negate whole list with {"$nor":[...]}), host_folder "/OU/path".

Choose scope + conditions from ONLY these real values; if the request names something absent, put it in
conditions anyway (the reviewer sees the blast radius). Prefer the most specific correct scope.
"""


def _prompt_context(ou_paths, groups, sites, tag_keys, fact_keys, var_keys) -> str:
    def show(label, items):
        items = sorted(items)
        return f"{label}: " + (", ".join(items[:80]) if items else "(none)")
    return "\n".join([
        show("OU paths", ou_paths),
        show("Host groups", groups),
        show("Sites", sites),
        show("Host tag keys", tag_keys),
        show("Ansible fact keys", fact_keys),
        show("Variable keys", var_keys),
    ])


def _parse_json_object(text: str) -> dict[str, Any]:
    """Extract the first JSON object from the model's reply, tolerating fences."""
    t = (text or "").strip()
    t = re.sub(r"^```(?:json)?|```$", "", t, flags=re.MULTILINE).strip()
    start = t.find("{")
    if start < 0:
        raise ValueError("model returned no JSON object")
    depth = 0
    for i in range(start, len(t)):
        if t[i] == "{":
            depth += 1
        elif t[i] == "}":
            depth -= 1
            if depth == 0:
                return json.loads(t[start : i + 1])
    raise ValueError("unterminated JSON object in model reply")


async def propose_policy_from_nl(
    session: AsyncSession, settings: Settings, instruction: str, backend_name: str | None = None
) -> dict[str, Any]:
    """Return {proposal, blast_radius, applied:false, note}. Never writes."""
    ou_paths = [p for (p,) in (await session.execute(select(OUNode.path))).all() if p]
    groups = [n for (n,) in (await session.execute(select(HostGroup.name))).all() if n]
    sites = [n for (n,) in (await session.execute(select(Site.name))).all() if n]
    tag_keys: set[str] = set()
    fact_keys: set[str] = set()
    for a in (await session.scalars(select(Agent))).all():
        tag_keys.update(str(k) for k in (a.tags or {}).keys())
        fact_keys.update(flatten_facts(a.facts or {}).keys())
    var_keys: set[str] = set()
    for sv in (await session.scalars(select(ScopeVars))).all():
        var_keys.update(str(k) for k in (sv.vars or {}).keys())

    context = _prompt_context(ou_paths, groups, sites, tag_keys, fact_keys, var_keys)
    backend = chat_backend_for(settings, backend_name)
    messages = [
        {"role": "system", "content": _SYSTEM + "\n\nAvailable in this fleet:\n" + context},
        {"role": "user", "content": instruction},
    ]
    try:
        res = await backend.complete_with_tools(messages, [], model=None)
    except ChatBackendError as exc:
        raise ValueError(f"LLM backend error: {exc}") from exc
    proposal = _parse_json_object(res.get("content", ""))

    # Resolve the scope name → id for a blast-radius preview (read-only).
    scope = proposal.get("scope") or {}
    stype = scope.get("type", "global")
    sname = scope.get("name")
    kwargs: dict[str, Any] = {}
    if stype == "ou" and sname:
        row = await session.scalar(select(OUNode).where(OUNode.path == sname))
        kwargs["ou_id"] = row.id if row else None
    elif stype == "group" and sname:
        row = await session.scalar(select(HostGroup).where(HostGroup.name == sname))
        kwargs["host_group_id"] = row.id if row else None
    elif stype == "site" and sname:
        row = await session.scalar(select(Site).where(Site.name == sname))
        kwargs["site_id"] = row.id if row else None

    blast: dict[str, Any]
    if stype in ("ou", "group", "site", "global"):
        blast = await whatif_scope(session, stype, conditions=proposal.get("conditions") or {}, **kwargs)
    else:
        blast = {"total_in_scope": 0, "matched_count": 0, "matched": [], "excluded": []}

    return {
        "applied": False,
        "proposal": proposal,
        "blast_radius": blast,
        "note": "Proposal only — review, then create it (dry_run first) to apply.",
    }
