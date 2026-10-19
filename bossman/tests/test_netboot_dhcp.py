"""The PXE DHCP policy (services/netboot_dhcp.py): restricted to armed MACs, open only for a bounded window
when a job has no MAC, off otherwise — and GET /api/v1/netboot/config carries it to the pxe container.

Real rows in the shared DB, so the assertions only look at the MACs this test armed (other suites may have
active jobs of their own); the window test uses a fixed `now`.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import delete

from bossman.db.models import DiskImage, RestoreJob
from bossman.services import netboot_dhcp

TAG = uuid.uuid4().hex[:8]
MAC = "bc:24:11:%s:%s:%s" % (TAG[0:2], TAG[2:4], TAG[4:6])


@pytest.fixture
async def image(db_session):
    img = DiskImage(name=f"dhcp-img-{TAG}", status="ready")
    db_session.add(img)
    await db_session.commit()
    yield img
    await db_session.execute(delete(RestoreJob).where(RestoreJob.target_hostname.like(f"dhcp-{TAG}%")))
    await db_session.execute(delete(DiskImage).where(DiskImage.id == img.id))
    await db_session.commit()


async def _job(db_session, image, mac: str, suffix: str, created_at=None):
    job = RestoreJob(image_id=image.id, target_mac=mac, target_hostname=f"dhcp-{TAG}-{suffix}", status="pending")
    if created_at is not None:
        job.created_at = created_at
    db_session.add(job)
    await db_session.commit()
    return job


async def test_disabled_is_off(db_session):
    pol = await netboot_dhcp.policy(db_session, enabled=False, open_minutes=15)
    assert pol == {"dhcp": False, "dhcp_mode": "off", "dhcp_macs": [], "dhcp_hosts": [], "dhcp_open_until": None,
                   "dhcp_reason": "netboot is disabled"}


async def test_a_mac_job_restricts_to_that_mac(db_session, image):
    await _job(db_session, image, MAC, "mac")
    pol = await netboot_dhcp.policy(db_session, enabled=True, open_minutes=15)
    assert pol["dhcp"] is True and MAC in pol["dhcp_macs"]
    # Unless another suite holds an open wildcard job right now, this is restricted.
    assert pol["dhcp_mode"] in ("restricted", "open")
    if pol["dhcp_mode"] == "restricted":
        assert MAC in pol["dhcp_reason"]


async def test_each_mac_gets_its_checked_static_address(db_session, image):
    # Three parallel installs exhausted a two-address PXE range; a netinstall MAC now gets exactly its checked address.
    from types import SimpleNamespace

    assert netboot_dhcp.static_address(SimpleNamespace(network={"address": "10.251.7.42/24"})) == "10.251.7.42"
    assert netboot_dhcp.static_address(SimpleNamespace(network={"mode": "dhcp"})) is None
    await _job(db_session, image, MAC, "static")
    pol = await netboot_dhcp.policy(db_session, enabled=True, open_minutes=15)
    assert {"mac": MAC, "address": None} in pol["dhcp_hosts"]   # a restore job keeps using the range
    assert [h["mac"] for h in pol["dhcp_hosts"]] == pol["dhcp_macs"]


async def test_a_wildcard_job_opens_only_for_its_window(db_session, image):
    armed = datetime(2030, 1, 1, 12, 0, tzinfo=timezone.utc)
    await _job(db_session, image, "", "wild", created_at=armed)
    inside = await netboot_dhcp.policy(db_session, enabled=True, open_minutes=15, now=armed + timedelta(minutes=5))
    assert inside["dhcp_mode"] == "open" and inside["dhcp_open_until"] == (armed + timedelta(minutes=15)).isoformat()
    after = await netboot_dhcp.policy(db_session, enabled=True, open_minutes=15, now=armed + timedelta(minutes=16))
    assert after["dhcp_mode"] != "open"
    if after["dhcp_mode"] == "off":
        assert "open window ended" in after["dhcp_reason"]


async def test_netboot_config_carries_the_policy(db_session, image, monkeypatch):
    from fastapi.testclient import TestClient

    from bossman.db.models import Agent
    from bossman.main import create_app

    await _job(db_session, image, MAC, "cfg")
    agent = Agent(name=f"dhcp-{TAG}-pxe", token=f"tok-{TAG}", address="10.0.0.9:8051", mode="standalone",
                  enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.commit()
    try:
        with TestClient(create_app()) as client:
            r = client.get("/api/v1/netboot/config", headers={"Authorization": f"Bearer tok-{TAG}"})
        assert r.status_code == 200, r.text
        body = r.json()
        assert {"dhcp", "dhcp_mode", "dhcp_macs", "dhcp_reason"} <= set(body)
        if body["enabled"]:
            assert MAC in body["dhcp_macs"]
    finally:
        await db_session.delete(agent)
        await db_session.commit()
