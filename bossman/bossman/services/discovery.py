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
    # Checkmk's service labels, discovered WITH the service and stored in the
    # autocheck. They are half of the change comparator (see
    # services/discovery_lifecycle.ServiceRecord.comparator), so they have to
    # travel with the item rather than being fetched separately later.
    service_labels: dict[str, str] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "item": self.item,
            "params": self.params,
            "metrics": self.metrics,
            "service_labels": self.service_labels,
        }


@dataclass
class CheckProposal:
    check_name: str
    items: list[DiscoveredItem]
    short_description: str = ""
    # required option names with no default — the wizard must collect these
    # (e.g. a DB user/password) before the check can run for real.
    needs_params: list[str] = field(default_factory=list)
    error: str = ""
    # Host labels this check's discovery reported. In Checkmk these come from a
    # SECTION's host_label_function and are host-wide, not per item — so they sit
    # on the proposal, and the caller merges them across all checks.
    host_labels: dict[str, str] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "check_name": self.check_name,
            "short_description": self.short_description,
            "items": [i.to_dict() for i in self.items],
            "needs_params": self.needs_params,
            "error": self.error,
            "host_labels": self.host_labels,
        }


def _str_map(raw: Any) -> dict[str, str]:
    """A check's label dict, coerced to str->str.

    Labels come from a Starlark module, so a value can arrive as a number or bool;
    Checkmk's own loader coerces the same way (AutocheckEntry._parse_labels). A
    non-dict is dropped rather than guessed at.
    """
    if not isinstance(raw, dict):
        return {}
    return {str(k): str(v) for k, v in raw.items()}


def _fetched_data(result: Any) -> bool:
    """Did the module's read calls actually return anything?

    Reads the agent's `data_source: {attempts, produced}` (internal/starmod's
    Recorder). A check that made no read calls at all reports nothing here — that
    is treated as unknown and kept, since inventing a second reason to drop a
    check is worse than the occasional false positive.
    """
    if not isinstance(result, dict):
        return True
    ds = result.get("data_source")
    if not isinstance(ds, dict):
        # No field at all → an older agent that cannot answer. Keep the check;
        # a missing capability must not narrow discovery.
        return True
    # A check that made NO read call did not look at the host. `mkevents` is the
    # case in the library: zero ctx.run/ctx.file_read calls, yet it reported OK and
    # was offered on every host. Since the agent now always reports this field,
    # attempts==0 is a real answer ("observed nothing"), not a missing one.
    return int(ds.get("produced") or 0) > 0


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
    # Same two-part test as the item-less path: a gradeable state AND evidence that
    # the check's reads actually returned something.
    return state in ("OK", "WARN", "CRIT") and _fetched_data(probe)


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


# The check_name under which a Docker container is discovered as a monitorable service. Shared with
# the apply path (api/checks.py), which recomputes the agent's monitored-container allow-list from every
# DiscoveredService carrying this name. One item per container, the item being the container's name.
CONTAINER_CHECK_NAME = "Docker container"


async def discover_containers(client) -> CheckProposal:
    """Offer every running container as a monitorable service.

    A container is NOT a library check — it is enumerated live from the host (GET /api/v1/containers)
    and turned into one DiscoveredItem per container. Accepting it puts its name on the agent's
    monitored-containers allow-list (see api/checks.py apply), which is what makes the agent start
    storing that container's docker_container_* series; removing the check takes it back off. Errors are
    reported on the proposal, never raised, exactly like a library check that fails to probe."""
    prop = CheckProposal(
        check_name=CONTAINER_CHECK_NAME,
        items=[],
        short_description="A running Docker container. Accept it to collect its CPU/memory/network metrics.",
    )
    try:
        names = await client.list_containers()
    except Exception as exc:  # noqa: BLE001 — one source failing must not sink the whole discovery run
        prop.error = str(exc)[:200]
        return prop
    prop.items = [DiscoveredItem(item=name) for name in sorted(names)]
    return prop


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
    declared_none = False
    try:
        result = await client.call_tool(fqcn, {"_discover": True})
        data = (result or {}).get("data") if isinstance(result, dict) else None
        discovery = (data or {}).get("discovery") if isinstance(data, dict) else None
        # An EMPTY list is an answer, not a missing one: the contract tells a check
        # to return `{"discovery": []}` when the thing it monitors is not on this
        # host. Conflating that with "this check has no discovery at all" sent
        # nfsexports and postgres_processes down the single-instance probe path and
        # proposed them anyway — right after they had been re-translated to say
        # honestly that they found nothing.
        declared_none = isinstance(discovery, list) and not discovery
        for entry in discovery or []:
            if not isinstance(entry, dict):
                continue
            prop.items.append(
                DiscoveredItem(
                    item=str(entry.get("item", "")),
                    params=entry.get("params") or {},
                    metrics=[str(m) for m in (entry.get("metrics") or [])],
                    service_labels=_str_map(entry.get("service_labels")),
                )
            )
        discovered = bool(prop.items)
        # Host labels are host-wide, so they sit next to `discovery` rather than
        # inside an item — Checkmk's equivalent is a section's host_label_function.
        if isinstance(data, dict):
            prop.host_labels = _str_map(data.get("host_labels"))
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

    if declared_none:
        return None  # the check itself says this host has nothing to monitor

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
        # …and the state alone is not enough, because a translated check will
        # happily report OK about data it never got. The agent now reports whether
        # the module's read calls actually produced anything (`data_source`), which
        # is our stand-in for Checkmk's "was the section fetched": a `pvecm status`
        # on a host without Proxmox returns rc 127 and nothing at all. If every
        # attempt came back empty, the check has no data source here.
        #
        # This path used to be filtered by accident: a missing binary made ctx.run
        # raise and killed the module. Once that became rc 127 (the shell's own
        # convention, and what let lnx_if work at all), pvecm/mongodb/plesk/hyperv
        # started passing — so the accident has to be replaced by a real test.
        if not _fetched_data(probe):
            return None
        prop.items.append(DiscoveredItem(item=""))

    return prop
