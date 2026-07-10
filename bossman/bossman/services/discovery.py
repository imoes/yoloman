"""Auto-discovery run (Block G9-P3c): run checks in their `_discover` mode on
a host and turn what they find into check proposals.

Mirrors Checkmk's service discovery: push the candidate check modules to the
agent, invoke each in discovery mode (params `_discover: true`), and collect
the items it reports (one per filesystem / file / sensor …, each with the
metrics discovered for it — see services/checkmk_translation's contract).
The result is a list of proposals the wizard / UI (or the AI) turns into
host-scoped CheckAssignments — after collecting any required params
(credentials) the check declares.

Pure orchestration over the AgentClient interface (push_modules + call_tool),
so it's unit-tested with a fake client and needs no live agent here.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any


@dataclass
class DiscoveredItem:
    item: str
    params: dict[str, Any] = field(default_factory=dict)
    metrics: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {"item": self.item, "params": self.params, "metrics": self.metrics}


@dataclass
class CheckProposal:
    check_name: str
    items: list[DiscoveredItem]
    short_description: str = ""
    # required option names with no default — the wizard must collect these
    # (e.g. a DB user/password) before the check can run for real.
    needs_params: list[str] = field(default_factory=list)
    error: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "check_name": self.check_name,
            "short_description": self.short_description,
            "items": [i.to_dict() for i in self.items],
            "needs_params": self.needs_params,
            "error": self.error,
        }


def _needs_params(options: dict[str, Any]) -> list[str]:
    """Required options with no default — the wizard/AI must ask for these."""
    out = []
    for name, spec in (options or {}).items():
        if isinstance(spec, dict) and spec.get("required") and spec.get("default") is None:
            out.append(name)
    return out


def _delivery(name: str, star: str, sidecar: str, sidecar_format: str) -> dict[str, Any]:
    """One module in the /api/v1/modules/apply push shape. The fqcn must be
    dotted for the agent's fqcn split; checks are flat, so namespace them
    under 'checks.<name>' — the module still registers under its sidecar
    `name` (== <name>), which is what call_tool uses."""
    return {
        "fqcn": f"checks.{name}",
        "star": star,
        "sidecar": sidecar,
        "sidecar_format": sidecar_format,
        "sha256": hashlib.sha256(star.encode()).hexdigest(),
    }


async def run_check_discovery(client, checks: list[dict[str, Any]]) -> list[CheckProposal]:
    """Push `checks` to the agent and run each in discovery mode.

    `checks` is a list of {name, star, sidecar, sidecar_format, options,
    short_description} (from the check library). `client` is an AgentClient
    (needs push_modules + call_tool). Returns one CheckProposal per check that
    discovered at least one item; checks that error or find nothing are
    reported (error / empty) but never raise."""
    if not checks:
        return []

    deliveries = [_delivery(c["name"], c["star"], c.get("sidecar", ""), c.get("sidecar_format", "yaml")) for c in checks]
    try:
        await client.push_modules(deliveries)
    except Exception as exc:  # noqa: BLE001 — a push failure fails the whole run, surfaced per-check
        return [CheckProposal(check_name=c["name"], items=[], short_description=c.get("short_description", ""), error=f"push failed: {exc}") for c in checks]

    proposals: list[CheckProposal] = []
    for c in checks:
        name = c["name"]
        prop = CheckProposal(
            check_name=name,
            items=[],
            short_description=c.get("short_description", ""),
            needs_params=_needs_params(c.get("options", {})),
        )
        try:
            result = await client.call_tool(name, {"_discover": True})
            data = (result or {}).get("data") if isinstance(result, dict) else None
            discovery = (data or {}).get("discovery") if isinstance(data, dict) else None
            for entry in discovery or []:
                if not isinstance(entry, dict):
                    continue
                prop.items.append(
                    DiscoveredItem(
                        item=str(entry.get("item", "")),
                        params=entry.get("params") or {},
                        metrics=[str(m) for m in (entry.get("metrics") or [])],
                    )
                )
        except Exception as exc:  # noqa: BLE001 — one bad check must not sink the run
            prop.error = str(exc)
        proposals.append(prop)

    # Only surface checks that apply (found items) or errored; drop the
    # silent "discovered nothing" ones — they don't apply to this host.
    return [p for p in proposals if p.items or p.error]
