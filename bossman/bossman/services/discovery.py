"""Auto-discovery run (Block G9-P3c): find the checks that actually apply to a
host and turn them into proposals.

Mirrors Checkmk's service discovery, whose core rule is "only a check whose
section/data is present on the host applies" (see cmk .../discovery/_discover/
services.py `_find_host_plugins`). Two gates:

  1. datasource pre-filter (api/checks._load_candidate_checks): a plain agent
     host never satisfies the SNMP checks, so they're not even candidates;
  2. a REAL relevance probe here: run each candidate in normal mode and keep it
     only if it produced actual data (state OK/WARN/CRIT). The translated
     `_discover` mode is unreliable — it returns a hardcoded placeholder item
     without touching the host — so trusting it made discovery list the whole
     library. `_discover` is used only for the item/metric shape of a check
     that already probed relevant.

The result is proposals the wizard / UI (or the AI) turns into host-scoped
CheckAssignments — after collecting any required params the check declares.

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


def _delivery(fqcn: str, star: str, sidecar: str, sidecar_format: str) -> dict[str, Any]:
    """One module in the /api/v1/modules/apply push shape. `fqcn` must be dotted
    (the agent splits it) — translated checks carry `checkmk.<name>`; custom
    checks are namespaced `checks.<name>`. The agent registers the tool under
    this fqcn, which is what run_check_discovery calls."""
    return {
        "fqcn": fqcn,
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

    deliveries = [
        _delivery(c.get("fqcn") or f"checks.{c['name']}", c["star"], c.get("sidecar", ""), c.get("sidecar_format") or "nt")
        for c in checks
    ]
    try:
        await client.push_modules(deliveries)
    except Exception as exc:  # noqa: BLE001 — a push failure fails the whole run, surfaced per-check
        return [CheckProposal(check_name=c["name"], items=[], short_description=c.get("short_description", ""), error=f"push failed: {exc}") for c in checks]

    proposals: list[CheckProposal] = []
    for c in checks:
        name = c["name"]
        fqcn = c.get("fqcn") or name
        prop = CheckProposal(
            check_name=name,
            items=[],
            short_description=c.get("short_description", ""),
            needs_params=_needs_params(c.get("options", {})),
        )
        # DISCOVERY-FIRST, exactly like Checkmk: a check's discovery_function
        # parses the host's section data and YIELDS one Service per item it
        # finds (each filesystem, NIC, sensor, pool). We mirror that by running
        # the check's `_discover` mode — 1141 of the translated checks implement
        # it for real (e.g. df runs `df -PT` and enumerates every mount). A check
        # is RELEVANT iff its discovery finds ≥1 item; that is the only signal
        # needed and the only one that scales to multi-item checks.
        #
        # (The old code instead ran a whole-host relevance probe with empty
        # params and kept the check only if it returned OK/WARN/CRIT. That
        # DROPPED every per-item check — df with no item returns UNKNOWN — so
        # discovery found none of the 10 filesystems. Discovery-first fixes it.)
        discovered = False
        try:
            result = await client.call_tool(fqcn, {"_discover": True})
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
            discovered = bool(prop.items)
        except Exception:  # noqa: BLE001 — a broken _discover falls through to the probe
            pass

        if not discovered:
            # No items from discovery. Either a single-instance check (uptime,
            # memory — one whole-host service, no items) or its section isn't
            # present. Distinguish with a normal probe: OK/WARN/CRIT means the
            # data source IS here → one item-less service; anything else (UNKNOWN
            # / error) means not applicable → skip.
            try:
                probe = await client.call_tool(fqcn, {})
                pdata = (probe or {}).get("data") if isinstance(probe, dict) else None
                state = str((pdata or {}).get("state", "")).upper() if isinstance(pdata, dict) else ""
            except Exception:  # noqa: BLE001
                state = ""
            if state not in ("OK", "WARN", "CRIT"):
                continue  # not applicable on this host
            prop.items.append(DiscoveredItem(item=""))

        proposals.append(prop)

    return proposals
