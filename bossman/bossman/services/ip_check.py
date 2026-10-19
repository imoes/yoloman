"""Is an IPv4 address free? Three sources, each named with what it said (docs/kernel-tuning.md, VM deployment).

Measured on 192.0.2.0/24 (2026-10-18): NetBox listed 192.0.2.225 and .226 as available while both
answered ARP on the wire — .225 was a VM Bossman itself had provisioned. So no single source decides:

* **bossman** — Bossman's own records: an agent's address, the IPv4 addresses in its inventory facts, and the
  static address a planned host will be given (`agent_metadata.provision_network.address`).
* **netbox** — the IPAM record, when NetBox is configured (BOSSMAN_NETBOX_URL plus a token, or a username and
  password for a read-only session). Not configured is a named state, not "free".
* **live** — an enrolled agent in the same subnet pings the address and reads its neighbour table. An ARP
  answer means in use even when ICMP is filtered. No agent in the subnet is a named state too.

Verdict: `in_use` when any source finds it; `free` only when the live probe ran and saw nothing and neither
record holds it; otherwise `unknown`, with the reason. A free verdict without a live probe would be the
NetBox mistake again.
"""
from __future__ import annotations

import ipaddress
import re
from typing import Any

import httpx
from sqlalchemy import select

from bossman.db.models import Agent

_PROBE = ('for a in "$@"; do ping -c 2 -W 1 -q "$a" >/dev/null 2>&1 && p=1 || p=0; '
          'n=$(ip neigh show "$a" 2>/dev/null | head -1); echo "$a|$p|$n"; done')


def _ipv4s_of(agent: Agent) -> set[str]:
    out: set[str] = set()
    host = (agent.address or "").rsplit(":", 1)[0]
    try:
        out.add(str(ipaddress.IPv4Address(host)))
    except ValueError:
        pass
    facts = agent.facts or {}
    for nic in facts.get("nics") or []:
        for a in nic.get("ipv4") or []:
            out.add(str(a).split("/")[0])
    planned = ((agent.agent_metadata or {}).get("provision_network") or {}).get("address")
    if planned:
        out.add(str(planned).split("/")[0])
    return out


async def bossman_holders(session, addresses: list[str]) -> dict[str, list[str]]:
    """address → names of agents (enrolled or planned) that hold it in Bossman's records."""
    want = set(addresses)
    found: dict[str, list[str]] = {a: [] for a in addresses}
    for agent in (await session.scalars(select(Agent))).all():
        for ip in _ipv4s_of(agent) & want:
            found[ip].append(agent.name)
    return found


class NetBox:
    """Minimal read-only NetBox client: a token (Authorization: Bearer/Token) or a session login."""

    def __init__(self, settings):
        self.url = (getattr(settings, "netbox_url", "") or "").rstrip("/")
        self.token = getattr(settings, "netbox_token", "") or ""
        self.username = getattr(settings, "netbox_username", "") or ""
        self.password = getattr(settings, "netbox_password", "") or ""

    @property
    def configured(self) -> bool:
        return bool(self.url and (self.token or (self.username and self.password)))

    async def _client(self) -> httpx.AsyncClient:
        c = httpx.AsyncClient(base_url=self.url, timeout=20, trust_env=False, follow_redirects=True,
                              headers={"Accept": "application/json"})
        if self.token:
            scheme = "Bearer" if self.token.startswith("nbt_") else "Token"
            c.headers["Authorization"] = f"{scheme} {self.token}"
            return c
        page = await c.get("/login/")
        m = re.search(r'name="csrfmiddlewaretoken" value="([^"]+)"', page.text)
        if not m:
            await c.aclose()
            raise RuntimeError("NetBox login page has no CSRF token")
        await c.post("/login/", data={"csrfmiddlewaretoken": m.group(1), "username": self.username,
                                      "password": self.password, "next": "/"}, headers={"Referer": self.url + "/login/"})
        return c

    async def recorded(self, addresses: list[str]) -> dict[str, list[str]]:
        """address → descriptions of the NetBox IP-address objects that record it."""
        out: dict[str, list[str]] = {a: [] for a in addresses}
        c = await self._client()
        try:
            for a in addresses:
                r = await c.get("/api/ipam/ip-addresses/", params={"address": a})
                r.raise_for_status()
                for row in r.json().get("results", []):
                    label = row.get("dns_name") or row.get("description") or f"id {row.get('id')}"
                    out[a].append(f"{label} ({(row.get('status') or {}).get('value', '?')})")
        finally:
            await c.aclose()
        return out

    async def available(self, prefix: str, limit: int) -> list[str]:
        c = await self._client()
        try:
            r = await c.get("/api/ipam/prefixes/", params={"prefix": prefix})
            r.raise_for_status()
            rows = r.json().get("results", [])
            if not rows:
                return []
            r = await c.get(f"/api/ipam/prefixes/{rows[0]['id']}/available-ips/", params={"limit": limit})
            r.raise_for_status()
            return [x["address"].split("/")[0] for x in r.json()]
        finally:
            await c.aclose()


async def _probe_agents(session, network: ipaddress.IPv4Network) -> list[Agent]:
    """Enrolled, addressable agents with an IPv4 address inside `network` that have REPORTED, freshest first.
    An agent that never reported (a host still being installed) is no probe: measured 2026-10-18, it was picked
    and every verdict in the subnet became unknown."""
    out = []
    for agent in (await session.scalars(select(Agent).where(Agent.enrollment_state == "enrolled"))).all():
        if not agent.address or agent.last_seen_at is None:
            continue
        if any(ipaddress.IPv4Address(ip) in network for ip in _ipv4s_of(agent)):
            out.append(agent)
    return sorted(out, key=lambda a: a.last_seen_at, reverse=True)


async def live_probe(session, settings, client_factory, addresses: list[str],
                     network: ipaddress.IPv4Network) -> tuple[str | None, dict[str, dict[str, Any]] | str]:
    """(probe agent name, {address: {ping, neighbour}}) or (None, reason). Tries up to three agents."""
    agents = await _probe_agents(session, network)
    if not agents:
        return None, f"no enrolled agent that has reported with an address in {network} to probe from"
    failures = []
    for agent in agents[:3]:
        try:
            res = await client_factory(agent, settings).call_tool(
                "command", {"argv": ["sh", "-c", _PROBE, "sh", *addresses]})
        except Exception as exc:  # noqa: BLE001 — the probe's failure is reported, never a verdict
            failures.append(f"{agent.name}: {str(exc)[:120]}")
            continue
        out: dict[str, dict[str, Any]] = {}
        for line in ((res.get("data") or {}).get("stdout") or "").splitlines():
            addr, _, rest = line.partition("|")
            ping, _, neigh = rest.partition("|")
            lladdr = re.search(r"lladdr ([0-9a-f:]{17})", neigh)
            failed = "FAILED" in neigh or "INCOMPLETE" in neigh
            out[addr] = {"ping": ping == "1", "mac": lladdr.group(1) if lladdr and not failed else None}
        return agent.name, out
    return None, "every probe agent failed: " + "; ".join(failures)


def _parse(addresses: list[str]) -> list[str]:
    out = []
    for a in addresses:
        try:
            out.append(str(ipaddress.IPv4Address(a.split("/")[0])))
        except ValueError as exc:
            raise ValueError(f"not an IPv4 address: {a!r}") from exc
    return out


async def check(session, settings, client_factory, addresses: list[str], prefix_len: int = 24) -> list[dict[str, Any]]:
    """One verdict per address, each with every source's answer."""
    addrs = _parse(addresses)
    if not addrs:
        return []
    network = ipaddress.IPv4Network(f"{addrs[0]}/{prefix_len}", strict=False)
    if any(ipaddress.IPv4Address(a) not in network for a in addrs):
        raise ValueError(f"all addresses must lie in one /{prefix_len} (the live probe runs in one subnet)")
    holders = await bossman_holders(session, addrs)
    nb = NetBox(settings)
    if nb.configured:
        try:
            nb_rec: dict[str, list[str]] | str = await nb.recorded(addrs)
        except Exception as exc:  # noqa: BLE001
            nb_rec = f"NetBox query failed: {str(exc)[:200]}"
    else:
        nb_rec = "not configured (BOSSMAN_NETBOX_URL + token or username/password)"
    prober, live = await live_probe(session, settings, client_factory, addrs, network)
    results = []
    for a in addrs:
        sources: dict[str, Any] = {"bossman": holders[a] or "no record"}
        sources["netbox"] = nb_rec if isinstance(nb_rec, str) else (nb_rec[a] or "no record")
        if isinstance(live, str):
            sources["live"] = live
            live_seen = None
        else:
            obs = live.get(a, {"ping": False, "mac": None})
            live_seen = bool(obs["ping"] or obs["mac"])
            sources["live"] = ({"via": prober, **obs} if live_seen else {"via": prober, "answer": "none"})
        if holders[a] or live_seen or (not isinstance(nb_rec, str) and nb_rec[a]):
            verdict, reason = "in_use", "; ".join(
                ([f"Bossman: {', '.join(holders[a])}"] if holders[a] else [])
                + ([f"answers on the wire via {prober}"] if live_seen else [])
                + ([f"NetBox: {', '.join(nb_rec[a])}"] if not isinstance(nb_rec, str) and nb_rec[a] else []))
        elif live_seen is None:
            verdict, reason = "unknown", "no live probe: " + str(live)
        else:
            verdict, reason = "free", (f"no record in Bossman, no answer via {prober}"
                                       + ("" if isinstance(nb_rec, str) else ", not recorded in NetBox"))
        results.append({"address": a, "verdict": verdict, "reason": reason, "sources": sources})
    return results


async def suggest(session, settings, client_factory, prefix: str, count: int = 5) -> dict[str, Any]:
    """Up to `count` addresses in `prefix` that every source agrees are free.

    Candidates come from NetBox's available-ips when configured, otherwise from the prefix's host range; each
    batch is checked with `check`, so NetBox's word alone never makes an address free."""
    network = ipaddress.IPv4Network(prefix, strict=False)
    nb = NetBox(settings)
    if nb.configured:
        candidates = await nb.available(str(network), limit=256)
        origin = "NetBox available-ips"
    else:
        candidates = [str(h) for h in network.hosts()]
        origin = "the prefix's host range (NetBox not configured)"
    free: list[dict[str, Any]] = []
    rejected: list[dict[str, Any]] = []
    for i in range(0, len(candidates), 16):
        batch = candidates[i:i + 16]
        for r in await check(session, settings, client_factory, batch, network.prefixlen):
            (free if r["verdict"] == "free" else rejected).append(r)
        if len(free) >= count or any(r["verdict"] == "unknown" for r in rejected):
            break
    return {"prefix": str(network), "candidates_from": origin, "free": free[:count],
            "rejected": [{"address": r["address"], "verdict": r["verdict"], "reason": r["reason"]} for r in rejected]}
