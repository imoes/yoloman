"""Periodic CVE collection (Block 4-C/4-D).

The fleet Security page is backed by persisted HostCve rows. This module fills
them: per host, fetch package_updates, correlate to the CVEs each upgrade
fixes, and replace that agent's rows. ``collect_all_hosts`` runs after each CVE
feed refresh (see main.py) so the page reflects the fleet without anyone having
to open each host — the user's "poller collects periodically" choice.
"""

from __future__ import annotations

import asyncio
import logging

from sqlalchemy import delete as sa_delete, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Agent, HostCve
from bossman.services.agent_client import AgentClientError, client_for
from bossman.services.cve_correlate import correlate

logger = logging.getLogger("bossman.cve_collect")


def _tool_data(result) -> dict:
    if isinstance(result, dict):
        d = result.get("data", result)
        return d if isinstance(d, dict) else {}
    return {}


async def collect_host(session: AsyncSession, agent: Agent, client, feed) -> list[dict]:
    """Fetch one host's pending updates, correlate, and replace its HostCve rows."""
    result = await client.call_tool("yoloman.package_updates", {"state": "list"})
    rows = correlate(feed, _tool_data(result))
    await session.execute(sa_delete(HostCve).where(HostCve.agent_id == agent.id))
    for r in rows:
        session.add(HostCve(agent_id=agent.id, **r))
    await session.commit()
    return rows


async def collect_all_hosts(session_factory: async_sessionmaker[AsyncSession], settings: Settings, feed, client_factory=client_for) -> int:
    """Correlate every enrolled, directly-reachable host. Best-effort: one
    host's failure never sinks the sweep. Returns the number of hosts collected."""
    async with session_factory() as session:
        agents = (await session.execute(
            select(Agent).where(Agent.enrollment_state == "enrolled", Agent.address.is_not(None))
        )).scalars().all()

    sem = asyncio.Semaphore(max(1, settings.poll_concurrency))
    ok = 0

    async def one(agent: Agent) -> None:
        nonlocal ok
        async with sem:
            try:
                async with session_factory() as session:
                    client = client_factory(agent, settings)
                    await collect_host(session, agent, client, feed)
                    ok += 1
            except AgentClientError:
                pass  # host offline / no package_updates module — skip
            except Exception:  # noqa: BLE001 — never let one host sink the sweep
                logger.warning("cve collect failed for agent %s", agent.id, exc_info=True)

    await asyncio.gather(*(one(a) for a in agents))
    logger.info("cve collect swept %d/%d hosts", ok, len(agents))
    return ok
