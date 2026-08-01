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
    DEB_NAME,
    POLICY_RC_PATH,
    SERVICE_NAME,
    install_succeeded,
    offline_install_script,
    offline_install_steps,
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
    plan = plan_offline_install(settings, "new-host.example")
    staged = {f.path for f in plan.files}
    for name in ("server.key", "server.crt", "bossman.pub.pem", "config.yaml", "policy-rc.d"):
        assert f"{plan.staging_dir}/{name}" in staged
    # And nothing staged that the script ignores.
    for path in staged:
        assert path.rsplit("/", 1)[-1] in plan.script


def test_staged_modes_match_what_the_script_installs(settings):
    plan = plan_offline_install(settings, "new-host.example")
    modes = {f.path.rsplit("/", 1)[-1]: f.mode for f in plan.files}
    assert modes["server.key"] == 0o600
    assert modes["config.yaml"] == 0o600
    assert modes["policy-rc.d"] == 0o755  # must be executable or invoke-rc.d ignores it


def test_policy_rc_d_denies_with_101(settings):
    """101 specifically: invoke-rc.d treats it as "forbidden by policy" and succeeds. Any other
    non-zero exit is an error and fails the dpkg run."""
    plan = plan_offline_install(settings, "new-host.example")
    body = next(f.data for f in plan.files if f.path.endswith("policy-rc.d")).decode()
    assert body.startswith("#!/bin/sh")
    assert "exit 101" in body


def test_config_is_the_shared_renderer_with_this_target_s_token(settings):
    plan = plan_offline_install(settings, "new-host.example", port=9999, write=True)
    config = next(f.data for f in plan.files if f.path.endswith("config.yaml")).decode()
    assert f'token: "{plan.token}"' in config
    assert 'listen: "0.0.0.0:9999"' in config
    assert "write: true" in config
    assert plan.listen_port == 9999


def test_each_target_gets_its_own_token_and_staging_dir(settings):
    """Two machines built from the same image must not share a bearer token — that is the difference
    between cloning a disk and cloning an identity."""
    a = plan_offline_install(settings, "a.example")
    b = plan_offline_install(settings, "b.example")
    assert a.token != b.token
    assert a.staging_dir != b.staging_dir


def test_blank_host_is_refused(settings):
    with pytest.raises(DeployError, match="must not be empty"):
        plan_offline_install(settings, "   ")


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


# --------------------------------------------------------------------------------------------------
# Turning the plan into helper steps
# --------------------------------------------------------------------------------------------------


@pytest.fixture
def steps(settings):
    from bossman.services.offline_enroll import offline_install_steps

    plan = plan_offline_install(settings, "new-host.example")
    return plan, offline_install_steps(plan, deb_url="https://store.example/agent.deb")


def test_only_the_install_itself_runs_inside_the_target(steps):
    """The split is dictated by which binaries exist where, and getting it wrong fails on real
    hardware only: `curl` and `base64` are in the helper image because we put them there, and a
    minimal Debian target may have neither. `dpkg`/`install`/`systemctl` are in the target."""
    _, plan_steps = steps
    chrooted = [s.name for s in plan_steps if s.chroot]
    assert chrooted == ["install the agent into the target"]


def test_staging_happens_under_the_mounted_target_not_the_helper_s_own_root(steps):
    """A helper-side path missing the TARGET_ROOT prefix would write the key into the RAM disk that is
    about to disappear, and the chroot step would then find nothing."""
    from bossman.services.imaging import TARGET_ROOT

    plan, plan_steps = steps
    for step in plan_steps:
        if step.chroot:
            continue
        text = " ".join(step.argv) if step.argv else step.shell
        if plan.staging_dir in text:
            assert f"{TARGET_ROOT}{plan.staging_dir}" in text


def test_the_chroot_step_uses_target_relative_paths(steps):
    """Mirror image of the previous test: inside the chroot the target root IS `/`, so a step carrying
    the TARGET_ROOT prefix would look for /mnt/target/mnt/target/… and fail."""
    from bossman.services.imaging import TARGET_ROOT

    plan, plan_steps = steps
    install = next(s for s in plan_steps if s.chroot)
    assert TARGET_ROOT not in install.shell
    assert plan.staging_dir in install.shell


def test_the_package_is_fetched_before_it_is_installed(steps):
    plan, plan_steps = steps
    names = [s.name for s in plan_steps]
    assert names.index("fetch the agent package") < names.index("install the agent into the target")
    fetch = next(s for s in plan_steps if s.name == "fetch the agent package")
    assert "https://store.example/agent.deb" in fetch.argv
    # -f so an HTML error page is not silently saved as the package; --retry because failing here
    # leaves a restored but un-enrolled machine.
    assert "-fsSL" in fetch.argv and "--retry" in fetch.argv


def test_the_stage_dir_exists_before_anything_is_written_into_it(steps):
    _, plan_steps = steps
    assert plan_steps[0].name == "stage dir for the agent install"
    assert plan_steps[0].argv[:2] == ("mkdir", "-p")


def test_every_staged_file_is_written_and_chmodded(steps):
    plan, plan_steps = steps
    shells = "\n".join(s.shell for s in plan_steps if s.shell and not s.chroot)
    for f in plan.files:
        name = f.path.rsplit("/", 1)[-1]
        assert f"/{name}" in shells, f"{name} never written"
        assert f"chmod {f.mode:04o}" in shells


def test_the_bearer_token_never_appears_as_a_shell_argument(steps):
    """base64 through a pipe is not decoration: a token on a command line is visible to any `ps` on
    the helper for as long as the step runs."""
    plan, plan_steps = steps
    for step in plan_steps:
        text = " ".join(step.argv) if step.argv else step.shell
        if step.chroot:
            continue  # the chroot script references the config by PATH, never by content
        assert plan.token not in text


def test_staged_content_round_trips_through_the_base64_pipeline(steps):
    """Decode what the step would actually run, so mangled quoting or encoding shows up here rather
    than as an agent that will not start on a machine in another building.

    Parsed with shlex rather than a regex over quote characters: base64's alphabet is entirely inside
    shlex.quote's safe set, so it emits the payload UNQUOTED — a pattern expecting quotes matches
    nothing and the test passes vacuously (it did, the first time).
    """
    import base64 as b64

    plan, plan_steps = steps
    by_name = {}
    for step in plan_steps:
        if not step.shell or step.chroot:
            continue
        tokens = shlex.split(step.shell)
        # printf %s <payload> | base64 -d > <path> && chmod <mode> <path>
        if tokens[:2] != ["printf", "%s"]:
            continue
        payload = tokens[2]
        path = tokens[tokens.index(">") + 1] if ">" in tokens else tokens[-1]
        by_name[path.rsplit("/", 1)[-1]] = b64.b64decode(payload)

    assert len(by_name) == len(plan.files), f"parsed {sorted(by_name)} from {len(plan.files)} files"
    for f in plan.files:
        assert by_name[f.path.rsplit("/", 1)[-1]] == f.data


# --------------------------------------------------------------------------------------------------
# Placement inside the restore plan
# --------------------------------------------------------------------------------------------------


def _plan_with(settings, configure=True):
    """Reuse the imaging suite's real fixtures rather than hand-rolling a layout — those are the ones
    already checked against actual `sfdisk`/`lsblk` output."""
    from bossman.services import imaging
    from bossman.services.offline_enroll import offline_install_steps
    from tests.test_imaging import SDA, SFDISK

    layout = imaging.parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    plan = imaging.plan_restore(layout, imaging.Disk("nvme0n1", 200 * 1024**3))
    steps = ()
    if configure:
        install = plan_offline_install(settings, "web07.example")
        steps = offline_install_steps(install, deb_url="https://s/agent.deb")
    return imaging.restore_steps(
        layout, plan, image_url="https://s/i", hostname="web07.example", configure_steps=steps
    )


def test_configure_steps_land_after_identity_and_before_the_unmount(settings):
    """Position is the requirement, not a detail. Earlier than the bind mounts and `dpkg` has no
    /proc; later than the unmount and there is no target left to install into. And after the identity
    reset, so a hostname changing underneath cannot invalidate what was just written."""
    names = [s.name for s in _plan_with(settings)]
    agent_install = names.index("install the agent into the target")
    assert names.index("bind /proc") < agent_install, "dpkg needs /proc"
    assert names.index("reset machine-id") < agent_install, "identity settles first"
    assert agent_install < names.index("unbind /proc")
    assert names.index("unbind /proc") < names.index("umount root")


def test_no_configure_steps_leaves_the_plan_exactly_as_before(settings):
    """The parameter must be additive: a machine restored without an agent install still gets the
    identical plan it got before any of this existed."""
    from bossman.services import imaging
    from tests.test_imaging import SDA, SFDISK

    layout = imaging.parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    plan = imaging.plan_restore(layout, imaging.Disk("nvme0n1", 200 * 1024**3))
    base = imaging.restore_steps(layout, plan, image_url="https://s/i", hostname="h")
    assert [s.name for s in base] == [s.name for s in _plan_with(settings, configure=False)][: len(base)]
    assert len(base) == len(_plan_with(settings, configure=False))


# ── network_steps (Block 4b): the target's final network written into the restored root ────────────

def test_network_steps_dhcp_or_empty_writes_nothing():
    assert offline_enroll.network_steps(None) == []
    assert offline_enroll.network_steps({}) == []
    assert offline_enroll.network_steps({"mode": "dhcp"}) == []


def test_network_steps_static_writes_networkd_and_enables_it():
    steps = offline_enroll.network_steps(
        {"mode": "static", "interface": "eth0", "address": "192.0.2.60/24",
         "gateway": "192.0.2.1", "dns": ["192.0.2.1", "1.1.1.1"]}
    )
    assert len(steps) == 2
    write = steps[0].shell
    assert "10-provision.network" in write
    for token in ("Name=eth0", "Address=192.0.2.60/24", "Gateway=192.0.2.1", "DNS=192.0.2.1", "DNS=1.1.1.1"):
        assert token in write
    assert steps[1].argv == ("systemctl", "enable", "systemd-networkd") and steps[1].chroot is True


def test_network_steps_static_without_interface_matches_any_ether():
    steps = offline_enroll.network_steps({"mode": "static", "address": "10.0.0.5/24"})
    assert "Type=ether" in steps[0].shell and "Name=" not in steps[0].shell
