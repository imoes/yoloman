"""Unit tests for the pure parts of the server-driven SSH deploy
(Block N-enroll, services/deploy.py). The SSH orchestration itself is
verified live against a real host — here we lock down the deterministic
config rendering + the misconfiguration guards, which are what a caller's
correctness actually hinges on.
"""

import pytest
import yaml

from bossman.config import Settings
from bossman.services.deploy import (
    AGENT_BOSSMAN_KEY_PATH,
    AGENT_SERVER_CERT_PATH,
    DeployError,
    deploy_and_enroll,
    render_agent_config,
)


def test_render_agent_config_is_valid_yaml_with_trust_wired():
    cfg = yaml.safe_load(render_agent_config(token="deadbeef", listen_port=18051, write=True))
    assert cfg["listen"] == "0.0.0.0:18051"
    assert cfg["token"] == "deadbeef"
    assert cfg["write"] is True
    assert cfg["tls"]["enabled"] is True
    assert cfg["tls"]["cert_file"] == AGENT_SERVER_CERT_PATH
    # Bossman's key is pinned as the single trusted client identity, so
    # only Bossman can reach the agent's mutating API over mTLS.
    trusted = cfg["tls"]["trusted_client_keys"]
    assert len(trusted) == 1
    assert trusted[0]["name"] == "bossman"
    assert trusted[0]["public_key_path"] == AGENT_BOSSMAN_KEY_PATH


def test_render_agent_config_write_false_is_literal_false():
    # A monitor-only host must serialize write as the YAML boolean false,
    # not the string "false" (which the Go loader would reject/misread).
    cfg = yaml.safe_load(render_agent_config(token="x", listen_port=18051, write=False))
    assert cfg["write"] is False


async def test_deploy_rejects_empty_host(db_session):
    settings = Settings(deploy_ssh_user="marvin", agent_deb_path="/opt/x.deb")
    with pytest.raises(DeployError, match="host must not be empty"):
        await deploy_and_enroll(db_session, settings, "   ")


async def test_deploy_requires_ssh_user(db_session):
    settings = Settings(deploy_ssh_user="", agent_deb_path="/opt/x.deb")
    with pytest.raises(DeployError, match="BOSSMAN_DEPLOY_SSH_USER"):
        await deploy_and_enroll(db_session, settings, "host.example.com")


async def test_deploy_requires_deb_path(db_session):
    settings = Settings(deploy_ssh_user="marvin", agent_deb_path="")
    with pytest.raises(DeployError, match="BOSSMAN_AGENT_DEB_PATH"):
        await deploy_and_enroll(db_session, settings, "host.example.com")


async def test_deploy_reports_missing_deb_file(db_session):
    settings = Settings(deploy_ssh_user="marvin", agent_deb_path="/nonexistent/agent.deb")
    with pytest.raises(DeployError, match="not found"):
        await deploy_and_enroll(db_session, settings, "host.example.com")
