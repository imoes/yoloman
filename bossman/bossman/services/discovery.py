"""Auto-discovery run (Block G9-P3c): find the checks that actually apply to a
host and turn them into proposals.

Mirrors Checkmk's service discovery, whose core rule is "only a check whose
section/data is present on the host applies" (see cmk .../discovery/_discover/
services.py `_find_host_plugins`). Two gates:

  1. datasource pre-filter (api/checks._load_candidate_checks): a plain agent
     host never satisfies the SNMP checks, so they're not even candidates;
  2. discovery-first + a data-present gate here: run each candidate's `_discover`
     to enumerate its items (a df yields every mount), THEN verify the data is
     really on the host by probing the first item — keep the check only if that
     grades OK/WARN/CRIT. Many translated `_discover` branches return a HARDCODED
     placeholder item without touching the host (e.g. every mongodb_* check), so
     trusting `_discover` alone listed the whole library on every host; the
     probe-verify step is our equivalent of Checkmk only discovering a check
     whose required section was actually fetched (`_find_host_plugins`).

The result is proposals the wizard / UI (or the AI) turns into host-scoped
CheckAssignments — after collecting any required params the check declares.

Pure orchestration over the AgentClient interface (push_modules + call_tool),
so it's unit-tested with a fake client and needs no live agent here.
"""

from __future__ import annotations

import asyncio
import hashlib
from dataclasses import dataclass, field
from typing import Any

# In-flight discovery probes. The work is I/O-bound (waiting on the agent), but
# the agent EXECUTES each check for real, so this caps the load we put on the
# host while still collapsing a minutes-long sequential run into seconds.
_DISCOVERY_CONCURRENCY = 16


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


async def _data_present(client, fqcn: str, item: "DiscoveredItem") -> bool:
    """Checkmk-style "is the section present" gate: run the check for REAL against
    one discovered item and report whether the host actually has the data. A
    placeholder `_discover` (which yields an item without touching the host, e.g.
    the MongoDB checks on a non-Mongo host) evaluates to UNKNOWN / "data not
    available" here → not present. Real data grades OK/WARN/CRIT → present."""
    params = dict(item.params or {})
    if item.item:
        # The instance key the translated checks read (df → params['item']);
        # set the common aliases so a real multi-item check verifies correctly.
        params.setdefault("item", item.item)
        params.setdefault("service_name", item.item)
    try:
        probe = await client.call_tool(fqcn, params)
    except Exception:  # noqa: BLE001 — unreachable/erroring check ⇒ treat as absent
        return False
    pdata = (probe or {}).get("data") if isinstance(probe, dict) else None
    state = str((pdata or {}).get("state", "")).upper() if isinstance(pdata, dict) else ""
    return state in ("OK", "WARN", "CRIT")


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

    # Discovery probes EVERY candidate check on the host — with ~1400 agent-datasource
    # checks at ~0.2-0.3s per round-trip (some need two), running them one after the
    # other took MINUTES, long enough that the browser gave up on the request and
    # Angular reported a bare "status 0". The work is pure I/O waiting on the agent,
    # so it parallelises cleanly; the cap keeps us from flooding the agent (which
    # executes each check for real) while still turning minutes into seconds.
    sem = asyncio.Semaphore(_DISCOVERY_CONCURRENCY)

    async def _one(c: dict[str, Any]) -> CheckProposal | None:
        async with sem:
            return await _discover_one(client, c)

    results = await asyncio.gather(*[_one(c) for c in checks], return_exceptions=True)
    proposals: list[CheckProposal] = []
    for c, res in zip(checks, results, strict=False):
        if isinstance(res, BaseException):
            # never let one broken check sink the run — report it like the
            # sequential version did and carry on
            proposals.append(CheckProposal(check_name=c["name"], items=[],
                                           short_description=c.get("short_description", ""),
                                           error=str(res)[:200]))
        elif res is not None:
            proposals.append(res)
    return proposals


async def _discover_one(client, c: dict[str, Any]) -> CheckProposal | None:
    """Probe ONE check on the host. Returns the proposal when the check applies,
    None when it doesn't (unchanged semantics — this is the body of what used to
    be the sequential loop)."""
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

    if discovered:
        # `_discover` yielded items — but ~240 translated checks yield a
        # HARDCODED placeholder item without touching the host (e.g. every
        # mongodb_* check on a host with no MongoDB). Verify the data is
        # really present by probing the first item; drop the check if it
        # isn't. This is our equivalent of Checkmk only running a check whose
        # required section was actually fetched from the host.
        if not await _data_present(client, fqcn, prop.items[0]):
            return None  # placeholder discovery / data absent → not applicable

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
            return None  # not applicable on this host
        prop.items.append(DiscoveredItem(item=""))

    return prop
