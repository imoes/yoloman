"""Bare-metal deployment API: images, restore jobs, and the netboot check-in.

The check-in is where the restore is planned, because the target's real disk size is not known until
the machine boots and says so — and that size decides how far the last volume grows. So most of what
matters here is tested through that endpoint.
"""

import uuid

from fastapi.testclient import TestClient
from sqlalchemy import delete, select

from bossman.db.models import AccessGrant, Agent, DiskImage, RestoreJob
from bossman.main import create_app
from bossman.services.auth import new_api_token
from bossman.services.imaging import layout_to_dict, parse_layout

GiB = 1024**3
SECRET = "netboot-test-secret"

SDA = {
    "name": "sda", "type": "disk", "size": 50 * GiB, "fstype": None, "rm": False,
    "children": [
        {"name": "sda1", "type": "part", "size": 1 * GiB, "fstype": "vfat",
         "fsused": 8 * 1024**2, "mountpoint": "/boot/efi"},
        {"name": "sda2", "type": "part", "size": 2 * GiB, "fstype": "ext4",
         "fsused": 300 * 1024**2, "mountpoint": "/boot"},
        {"name": "sda3", "type": "part", "size": 46 * GiB, "fstype": "LVM2_member", "fsused": None,
         "children": [
             {"name": "ubuntu--vg-ubuntu--lv", "type": "lvm", "size": 46 * GiB, "fstype": "ext4",
              "fsused": 6 * GiB, "mountpoint": "/"},
         ]},
    ],
}
SFDISK = {"partitiontable": {"label": "gpt", "sectorsize": 512, "partitions": [
    {"node": "/dev/sda1", "type": "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"},
    {"node": "/dev/sda2", "type": "0FC63DAF-8483-4772-8E79-3D69D8477DE4"},
    {"node": "/dev/sda3", "type": "E6D6D379-F507-44C2-A23C-238F2A3DF928"},
]}}

# What a booted target reports about itself: a much bigger disk than the source had.
TARGET_DEVICES = [
    {"name": "loop0", "type": "loop", "rm": False, "size": 4096},
    {"name": "nvme0n1", "type": "disk", "rm": False, "size": 400 * GiB},
    {"name": "sdb", "type": "disk", "rm": True, "size": 64 * GiB},
]


async def _token(db_session):
    name = f"img-caller-{uuid.uuid4().hex[:6]}"
    row, raw = new_api_token(name)
    db_session.add(row)
    db_session.add(AccessGrant(subject_kind="api_token", subject_ref=name, scope="all"))
    await db_session.commit()
    return row, raw


def _h(raw):
    return {"Authorization": f"Bearer {raw}"}


async def _ready_image(db_session, name=None) -> DiskImage:
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    img = DiskImage(
        name=name or f"golden-{uuid.uuid4().hex[:6]}",
        status="ready",
        manifest=layout_to_dict(layout),
        files={"root-ubuntu-lv": {"name": "root-ubuntu-lv.pcl.zst", "bytes": 2 * GiB, "sha256": "x"}},
    )
    db_session.add(img)
    await db_session.commit()
    return img


async def _cleanup(db_session, *rows):
    for r in rows:
        if isinstance(r, DiskImage):
            await db_session.execute(delete(RestoreJob).where(RestoreJob.image_id == r.id))
    await db_session.flush()
    for r in rows:
        await db_session.delete(r)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Images


async def test_an_image_reports_its_shape_without_the_caller_reading_the_manifest(db_session):
    token, raw = await _token(db_session)
    img = await _ready_image(db_session)
    with TestClient(create_app()) as client:
        body = client.get(f"/api/v1/images/{img.id}", headers=_h(raw)).json()
    assert body["disk_size"] == 50 * GiB
    assert [v["role"] for v in body["volumes"]] == ["esp", "boot", "root"]
    assert body["stored_bytes"] == 2 * GiB
    await _cleanup(db_session, img, token)


async def test_a_duplicate_image_name_is_a_conflict(db_session):
    token, raw = await _token(db_session)
    name = f"dup-{uuid.uuid4().hex[:6]}"
    with TestClient(create_app()) as client:
        first = client.post("/api/v1/images", json={"name": name}, headers=_h(raw))
        second = client.post("/api/v1/images", json={"name": name}, headers=_h(raw))
    assert first.status_code == 201 and second.status_code == 409
    img = await db_session.scalar(select(DiskImage).where(DiskImage.name == name))
    await _cleanup(db_session, img, token)


async def test_a_new_image_starts_out_capturing(db_session):
    """It is not deployable until the capture says so — see the ready-check on job creation."""
    token, raw = await _token(db_session)
    with TestClient(create_app()) as client:
        body = client.post("/api/v1/images", json={"name": f"cap-{uuid.uuid4().hex[:6]}"}, headers=_h(raw)).json()
    assert body["status"] == "capturing"
    img = await db_session.get(DiskImage, uuid.UUID(body["id"]))
    await _cleanup(db_session, img, token)


async def test_an_image_with_an_active_job_cannot_be_deleted(db_session):
    """The delete cascades to jobs, so removing it under a machine mid-install would take away the
    plan it is executing."""
    token, raw = await _token(db_session)
    img = await _ready_image(db_session)
    with TestClient(create_app()) as client:
        client.post(
            "/api/v1/restore-jobs",
            json={"image_id": str(img.id), "target_mac": "aa:bb:cc:00:00:01", "target_hostname": "h"},
            headers=_h(raw),
        )
        resp = client.delete(f"/api/v1/images/{img.id}", headers=_h(raw))
    assert resp.status_code == 409
    assert "still pending" in resp.text
    await _cleanup(db_session, img, token)


# ---------------------------------------------------------------------------
# Restore jobs


async def test_a_job_cannot_be_armed_from_an_unfinished_image(db_session):
    token, raw = await _token(db_session)
    img = DiskImage(name=f"half-{uuid.uuid4().hex[:6]}", status="capturing")
    db_session.add(img)
    await db_session.commit()
    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/restore-jobs",
            json={"image_id": str(img.id), "target_mac": "aa:bb:cc:00:00:02", "target_hostname": "h"},
            headers=_h(raw),
        )
    assert resp.status_code == 409 and "not ready" in resp.text
    await _cleanup(db_session, img, token)


async def test_mac_addresses_are_normalised_however_they_are_written(db_session):
    """PXE firmware, dnsmasq and operators spell the same machine three ways. Without normalising, a
    target checks in and finds no job that is plainly sitting right there — the most confusing
    failure available."""
    token, raw = await _token(db_session)
    img = await _ready_image(db_session)
    with TestClient(create_app()) as client:
        created = client.post(
            "/api/v1/restore-jobs",
            json={"image_id": str(img.id), "target_mac": "AA-BB-CC-DD-EE-01", "target_hostname": "h"},
            headers=_h(raw),
        )
        assert created.status_code == 201
        assert created.json()["target_mac"] == "aa:bb:cc:dd:ee:01"

        # The same machine, written as Cisco-style dotted hex, must collide.
        again = client.post(
            "/api/v1/restore-jobs",
            json={"image_id": str(img.id), "target_mac": "aabb.ccdd.ee01", "target_hostname": "h"},
            headers=_h(raw),
        )
        assert again.status_code == 409, "recognised as the same target"

        bad = client.post(
            "/api/v1/restore-jobs",
            json={"image_id": str(img.id), "target_mac": "not-a-mac", "target_hostname": "h"},
            headers=_h(raw),
        )
        assert bad.status_code == 422
    await _cleanup(db_session, img, token)


# ---------------------------------------------------------------------------
# The netboot check-in


async def _armed(db_session, client, raw, mac="aa:bb:cc:dd:ee:10", disk=None):
    img = await _ready_image(db_session)
    body = {"image_id": str(img.id), "target_mac": mac, "target_hostname": "web07"}
    if disk:
        body["target_disk"] = disk
    client.post("/api/v1/restore-jobs", json=body, headers=_h(raw))
    return img


def _secret_headers():
    return {"X-Netboot-Secret": SECRET}


async def test_checkin_is_refused_when_no_secret_is_configured(db_session, monkeypatch):
    """Fail closed: shipping this code must not open an unauthenticated install endpoint."""
    token, raw = await _token(db_session)
    with TestClient(create_app()) as client:
        img = await _armed(db_session, client, raw, mac="aa:bb:cc:dd:ee:11")
        resp = client.post(
            "/api/v1/netboot/checkin",
            json={"mac": "aa:bb:cc:dd:ee:11", "blockdevices": TARGET_DEVICES},
        )
    assert resp.status_code == 403
    assert "disabled" in resp.text
    await _cleanup(db_session, img, token)


async def test_checkin_plans_the_restore_against_the_disk_the_target_reports(db_session, monkeypatch):
    """The core of the feature, end to end through the API: a 50 GiB source arriving on a 400 GiB
    machine gets a plan whose last volume grows."""
    monkeypatch.setenv("BOSSMAN_NETBOOT_SECRET", SECRET)
    monkeypatch.setenv("BOSSMAN_IMAGE_BASE_URL", "https://boss.example")
    token, raw = await _token(db_session)
    if True:
        with TestClient(create_app()) as client:
            img = await _armed(db_session, client, raw, mac="aa:bb:cc:dd:ee:12")
            resp = client.post(
                "/api/v1/netboot/checkin",
                json={"mac": "AA:BB:CC:DD:EE:12", "blockdevices": TARGET_DEVICES},
                headers=_secret_headers(),
            )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["target_disk"] == "nvme0n1", "the largest non-removable disk, not sda"
        assert body["hostname"] == "web07"
        assert body["sfdisk_script"].startswith("label: gpt")
        names = [s["name"] for s in body["steps"]]
        assert "install bootloader" in names
        assert any(s["chroot"] for s in body["steps"])
        assert names.index("mount root") < names.index("mount boot")
        assert f"/images/{img.id}" in " ".join(s["shell"] for s in body["steps"] if s["shell"])

        job = await db_session.scalar(select(RestoreJob).where(RestoreJob.target_mac == "aa:bb:cc:dd:ee:12"))
        await db_session.refresh(job)
        assert job.status == "running"
        assert job.target_disk == "nvme0n1"
        assert len(job.steps) == len(body["steps"]), "the plan is stored, so a retry repeats it"
    await _cleanup(db_session, img, token)


async def test_checkin_without_a_job_says_so(db_session, monkeypatch):
    monkeypatch.setenv("BOSSMAN_NETBOOT_SECRET", SECRET)
    if True:
        with TestClient(create_app()) as client:
            resp = client.post(
                "/api/v1/netboot/checkin",
                json={"mac": "aa:bb:cc:00:00:99", "blockdevices": TARGET_DEVICES},
                headers=_secret_headers(),
            )
        assert resp.status_code == 404
        assert "no job armed" in resp.text


async def test_a_target_too_small_fails_the_job_where_an_operator_will_see_it(db_session, monkeypatch):
    """An unplannable restore is the job's failure, recorded on the row — not a 500 that exists only
    in a log the operator does not have."""
    monkeypatch.setenv("BOSSMAN_NETBOOT_SECRET", SECRET)
    token, raw = await _token(db_session)
    if True:
        with TestClient(create_app()) as client:
            img = await _armed(db_session, client, raw, mac="aa:bb:cc:dd:ee:13")
            resp = client.post(
                "/api/v1/netboot/checkin",
                json={
                    "mac": "aa:bb:cc:dd:ee:13",
                    "blockdevices": [{"name": "sda", "type": "disk", "rm": False, "size": 4 * GiB}],
                },
                headers=_secret_headers(),
            )
        assert resp.status_code == 409
        job = await db_session.scalar(select(RestoreJob).where(RestoreJob.target_mac == "aa:bb:cc:dd:ee:13"))
        await db_session.refresh(job)
        assert job.status == "failed"
        assert "bytes of data" in (job.error or "")
    await _cleanup(db_session, img, token)


async def test_progress_is_monotonic_and_the_log_is_bounded(db_session, monkeypatch):
    """A retried step must not make progress look like it went backwards — an operator watching a
    long install would read that as a loop. And a runaway helper must not fill the table."""
    monkeypatch.setenv("BOSSMAN_NETBOOT_SECRET", SECRET)
    token, raw = await _token(db_session)
    if True:
        with TestClient(create_app()) as client:
            img = await _armed(db_session, client, raw, mac="aa:bb:cc:dd:ee:14")
            job_id = client.post(
                "/api/v1/netboot/checkin",
                json={"mac": "aa:bb:cc:dd:ee:14", "blockdevices": TARGET_DEVICES},
                headers=_secret_headers(),
            ).json()["job_id"]

            client.post(f"/api/v1/netboot/progress/{job_id}",
                        json={"step_index": 12, "log": "x" * 100}, headers=_secret_headers())
            back = client.post(f"/api/v1/netboot/progress/{job_id}",
                               json={"step_index": 3, "log": "y" * 100_000}, headers=_secret_headers())
        assert back.json()["step_index"] == 12, "never regresses"
        job = await db_session.get(RestoreJob, uuid.UUID(job_id))
        await db_session.refresh(job)
        assert len(job.log) <= 64_000
    await _cleanup(db_session, img, token)


async def test_a_reported_failure_ends_the_job_and_frees_the_mac(db_session, monkeypatch):
    monkeypatch.setenv("BOSSMAN_NETBOOT_SECRET", SECRET)
    token, raw = await _token(db_session)
    if True:
        with TestClient(create_app()) as client:
            img = await _armed(db_session, client, raw, mac="aa:bb:cc:dd:ee:15")
            job_id = client.post(
                "/api/v1/netboot/checkin",
                json={"mac": "aa:bb:cc:dd:ee:15", "blockdevices": TARGET_DEVICES},
                headers=_secret_headers(),
            ).json()["job_id"]
            client.post(f"/api/v1/netboot/progress/{job_id}",
                        json={"step_index": 5, "failed": True, "error": "restore root: curl exited 22"},
                        headers=_secret_headers())
            # The MAC is free again, so the machine can be re-armed.
            again = client.post(
                "/api/v1/restore-jobs",
                json={"image_id": str(img.id), "target_mac": "aa:bb:cc:dd:ee:15", "target_hostname": "h"},
                headers=_h(raw),
            )
        assert again.status_code == 201
        job = await db_session.get(RestoreJob, uuid.UUID(job_id))
        await db_session.refresh(job)
        assert job.status == "failed" and "curl exited 22" in (job.error or "")
        assert job.finished_at is not None
    await _cleanup(db_session, img, token)
