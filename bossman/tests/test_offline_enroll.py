"""Tests for installing the agent into a mounted, not-yet-booted target.

The three assertions that carry the feature are the ones about what must NOT happen: dpkg must not
start the daemon, the script must not claim the service is running, and enrolment must not page for a
host that is still installing. Each of those is a way the install could look successful and be wrong.
"""

from __future__ import annotations

import shlex
from datetime import datetime, timedelta, timezone

import pytest
import pytest_asyncio

from bossman.services import offline_enroll
from bossman.services.deploy import (
    AGENT_BOSSMAN_KEY_PATH,
    AGENT_CONFIG_PATH,
    AGENT_SERVER_CERT_PATH,
    AGENT_SERVER_KEY_PATH,
    DeployError,
)
from bossman.services.offline_enroll import (
    POLICY_RC_PATH,
    SERVICE_NAME,
    install_succeeded,
    offline_install_script,
    plan_offline_install,
)


# --------------------------------------------------------------------------------------------------
# The install script
# --------------------------------------------------------------------------------------------------


def test_dpkg_is_bracketed_by_policy_rc_d():
    """The trap this guards: in a chroot, the package's maintainer script invokes the init helper.
    Without policy-rc.d that either fails the install or starts a daemon against the helper's kernel.
    Order is the whole point — installed BEFORE dpkg, removed AFTER."""
    script = offline_install_script(staging="/var/tmp/stage", deb_name="agent.deb")
    install_policy = script.index(f"install -m 0755 /var/tmp/stage/policy-rc.d {POLICY_RC_PATH}")
    dpkg = script.index("dpkg -i")
    remove_policy = script.index(f"rm -f {POLICY_RC_PATH}")
    assert install_policy < dpkg < remove_policy


def test_script_enables_for_next_boot_and_never_starts_or_restarts():
    """`systemctl start`/`restart` cannot work without an init, and `is-active` would report on the
    helper rather than the target — a plausible-looking lie. Only the offline verbs may appear."""
    script = offline_install_script(staging="/var/tmp/stage", deb_name="agent.deb")
    assert f"systemctl --root=/ enable {SERVICE_NAME}" in script
    assert f"systemctl --root=/ is-enabled {SERVICE_NAME}" in script
    for forbidden in ("systemctl restart", "systemctl start", "is-active", "daemon-reload"):
        assert forbidden not in script, f"{forbidden!r} is meaningless or misleading offline"


def test_script_aborts_on_the_first_failing_step():
    """Without `set -e` a failed dpkg would be followed by installing a config and enabling a unit
    that is not there, and the last line could still print `enabled`."""
    assert offline_install_script(staging="/s", deb_name="a.deb").startswith("set -e\n")


def test_identity_files_land_at_the_same_paths_as_an_ssh_deploy():
    """A machine installed offline and one installed over SSH must be the same machine afterwards.
    Sharing the path constants is what makes that true, so assert against them, not against copies."""
    script = offline_install_script(staging="/var/tmp/stage", deb_name="agent.deb")
    for path in (AGENT_SERVER_KEY_PATH, AGENT_SERVER_CERT_PATH, AGENT_BOSSMAN_KEY_PATH, AGENT_CONFIG_PATH):
        assert shlex.quote(path) in script


def test_private_key_and_config_are_not_world_readable():
    """The config carries the bearer token, so it is as sensitive as the key itself."""
    script = offline_install_script(staging="/var/tmp/stage", deb_name="agent.deb")
    assert f"install -m 0600 /var/tmp/stage/server.key {AGENT_SERVER_KEY_PATH}" in script
    assert f"install -m 0600 /var/tmp/stage/config.yaml {AGENT_CONFIG_PATH}" in script


def test_staging_is_removed_so_the_token_does_not_survive_into_the_running_system():
    script = offline_install_script(staging="/var/tmp/stage", deb_name="agent.deb")
    assert "rm -rf /var/tmp/stage" in script
    # …and after the config it protects has been placed, or we would delete our own input.
    assert script.index(AGENT_CONFIG_PATH) < script.index("rm -rf /var/tmp/stage")


def test_script_paths_are_absolute_because_the_chroot_resolves_them():
    """Unlike the SSH path there is no home directory to be relative to: the chroot capability
    resolves each argv path against the target root, so a relative path would resolve against
    whatever cwd the agent happens to have."""
    script = offline_install_script(staging="/var/tmp/stage", deb_name="agent.deb")
    for line in script.splitlines():
        for token in shlex.split(line) if not line.startswith("#") else []:
            if "var/tmp" in token or "etc/agentic-mcp" in token:
                assert token.startswith("/"), f"{token!r} is relative"


# --------------------------------------------------------------------------------------------------
# The plan
# --------------------------------------------------------------------------------------------------


@pytest.fixture
def settings(tmp_path):
    from bossman.config import Settings

    return Settings(
        client_key_path=str(tmp_path / "client.key"),
        client_cert_path=str(tmp_path / "client.crt"),
    )


def test_plan_stages_every_file_the_script_consumes(settings):
    """The failure this catches is a script referring to a file the plan never wrote — which fails
    only on real hardware, in the middle of an install."""
    plan = plan_offline_install(settings, "new-host.example", agent_deb=b"\x21\x3cdeb")
    staged = {f.path for f in plan.files}
    for name in ("agent.deb", "server.key", "server.crt", "bossman.pub.pem", "config.yaml", "policy-rc.d"):
        assert f"{plan.staging_dir}/{name}" in staged
    # And nothing staged that the script ignores.
    for path in staged:
        assert path.rsplit("/", 1)[-1] in plan.script


def test_staged_modes_match_what_the_script_installs(settings):
    plan = plan_offline_install(settings, "new-host.example", agent_deb=b"deb")
    modes = {f.path.rsplit("/", 1)[-1]: f.mode for f in plan.files}
    assert modes["server.key"] == 0o600
    assert modes["config.yaml"] == 0o600
    assert modes["policy-rc.d"] == 0o755  # must be executable or invoke-rc.d ignores it


def test_policy_rc_d_denies_with_101(settings):
    """101 specifically: invoke-rc.d treats it as "forbidden by policy" and succeeds. Any other
    non-zero exit is an error and fails the dpkg run."""
    plan = plan_offline_install(settings, "new-host.example", agent_deb=b"deb")
    body = next(f.data for f in plan.files if f.path.endswith("policy-rc.d")).decode()
    assert body.startswith("#!/bin/sh")
    assert "exit 101" in body


def test_config_is_the_shared_renderer_with_this_target_s_token(settings):
    plan = plan_offline_install(settings, "new-host.example", agent_deb=b"deb", port=9999, write=True)
    config = next(f.data for f in plan.files if f.path.endswith("config.yaml")).decode()
    assert f'token: "{plan.token}"' in config
    assert 'listen: "0.0.0.0:9999"' in config
    assert "write: true" in config
    assert plan.listen_port == 9999


def test_each_target_gets_its_own_token_and_staging_dir(settings):
    """Two machines built from the same image must not share a bearer token — that is the difference
    between cloning a disk and cloning an identity."""
    a = plan_offline_install(settings, "a.example", agent_deb=b"deb")
    b = plan_offline_install(settings, "b.example", agent_deb=b"deb")
    assert a.token != b.token
    assert a.staging_dir != b.staging_dir


def test_empty_package_is_refused_before_any_identity_is_minted(settings):
    """Better to fail here than to write a token and a trust anchor into a target that will never
    have an agent to use them."""
    with pytest.raises(DeployError, match="empty"):
        plan_offline_install(settings, "new-host.example", agent_deb=b"")


def test_blank_host_is_refused(settings):
    with pytest.raises(DeployError, match="must not be empty"):
        plan_offline_install(settings, "   ", agent_deb=b"deb")


@pytest.mark.parametrize(
    "output,expected",
    [
        ("Selecting previously unselected package…\nenabled", True),
        ("enabled\n", True),
        ("enabled  \n\n", True),
        ("disabled", False),
        ("enabled\nFailed to enable unit", False),  # our marker must be LAST, not merely present
        ("", False),
        ("Created symlink /etc/systemd/system/…", False),
    ],
)
def test_success_is_the_final_line_only(output, expected):
    assert install_succeeded(output) is expected


# --------------------------------------------------------------------------------------------------
# Enrolment: the new host must not alert while it is still being built
# --------------------------------------------------------------------------------------------------


@pytest_asyncio.fixture
async def enrolled(db_session):
    """Enrol test hosts and guarantee they are gone afterwards.

    `record_offline_agent` commits (both `enroll_agent` and `create_downtime` do), so the conftest
    session rollback does NOT undo it — these rows land in the database the running system polls.
    Leaving one behind is not merely untidy: an enrolled host that never reports becomes DOWN and
    CRITICAL once the install downtime expires, so a leaked test host pages for real. That is the same
    mistake `_drop_leaked_check_rules` exists to clean up after, so cleanup belongs in a fixture
    teardown where a failed assertion cannot skip it — not at the end of the test body.

    The cascade is imported from the delete route rather than reimplemented, so a new child table
    cannot leave this teardown quietly incomplete.
    """
    from sqlalchemy import text

    from bossman.api.agents import _AGENT_CHILD_DELETES

    created: list = []

    async def _enrol(host: str, **kwargs):
        agent = await offline_enroll.record_offline_agent(db_session, host, **kwargs)
        created.append(agent.id)
        return agent

    yield _enrol

    for agent_id in created:
        try:
            params = {"id": str(agent_id)}
            await db_session.execute(
                text("SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0")
            )
            for stmt in _AGENT_CHILD_DELETES:
                await db_session.execute(text(stmt), params)
            await db_session.execute(text("DELETE FROM agents WHERE id = :id"), params)
            await db_session.commit()
        except Exception:  # noqa: BLE001 — teardown must never turn a passing test red
            await db_session.rollback()


@pytest.mark.asyncio
async def test_enrolment_opens_a_host_downtime_across_the_install(db_session, enrolled):
    """The regression this pins: a stale agent now marks a host DOWN and CRITICAL. The agent row has
    to exist before the machine boots, so without a downtime every install pages for the gap between
    enrolment and first boot."""
    from bossman.services.monitoring import is_in_downtime

    now = datetime(2026, 7, 31, 3, 0, tzinfo=timezone.utc)
    agent = await enrolled("fresh-metal.example", token="t" * 64, listen_port=8080, now=now)

    assert agent.name == "fresh-metal.example"
    assert agent.address == "fresh-metal.example:8080"
    # Silent now, and still silent through the reboot…
    assert await is_in_downtime(db_session, agent.id, "Host alive", now)
    assert await is_in_downtime(db_session, agent.id, "Host alive", now + timedelta(minutes=30))
    # …but not forever: once the window passes, a host that never came up SHOULD alert.
    assert not await is_in_downtime(db_session, agent.id, "Host alive", now + timedelta(hours=2))


@pytest.mark.asyncio
async def test_downtime_covers_the_whole_host_not_one_service(db_session, enrolled):
    """Nothing about a half-installed machine is meaningful, so a service-scoped window would still
    let every other check page."""
    from sqlalchemy import select

    from bossman.db.models import Downtime

    agent = await enrolled("fresh-metal2.example", token="t" * 64, listen_port=8080)
    rows = (await db_session.execute(select(Downtime).where(Downtime.agent_id == agent.id))).scalars().all()
    assert [r.service_name for r in rows] == [None]


@pytest.mark.asyncio
async def test_reinstalling_the_same_host_refreshes_it_rather_than_duplicating(enrolled):
    """Re-imaging a machine is normal, and it must not accumulate fleet members. Upsert by name is
    the same rule the SSH deploy follows."""
    first = await enrolled("reused.example", token="a" * 64, listen_port=8080)
    second = await enrolled("reused.example", token="b" * 64, listen_port=8080)
    assert first.id == second.id
