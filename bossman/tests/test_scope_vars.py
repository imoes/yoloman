"""Block G11 — GPO variable resolution (group < OU root→leaf < host)."""

from uuid import uuid4
from tests.naming import run_suffix

from bossman.db.models import Agent, HostGroup, HostGroupMember, OUNode, ScopeVars
from bossman.services.scope_vars import resolve_scope_vars

TENANT = "00000000-0000-0000-0000-000000000001"


def _sfx():
    return run_suffix()


async def _ou(db_session, name, parent=None):
    s = _sfx()
    path = (parent.path if parent else "") + "/" + f"{name}-{s}"
    n = OUNode(id=uuid4(), tenant_id=TENANT, parent_id=(parent.id if parent else None), name=f"{name}-{s}",
               path=path, ltree_path=path.strip("/").replace("/", "."))
    db_session.add(n)
    await db_session.flush()
    return n


async def _agent(db_session, ou=None):
    a = Agent(id=uuid4(), name=f"sv-{_sfx()}", token="t", tenant_id=TENANT, ou_id=(ou.id if ou else None))
    db_session.add(a)
    await db_session.flush()
    return a


async def _vars(db_session, scope_type, vars, *, ou=None, group=None, agent=None):
    db_session.add(ScopeVars(id=uuid4(), tenant_id=TENANT, scope_type=scope_type,
                             ou_id=(ou.id if ou else None), host_group_id=(group.id if group else None),
                             agent_id=(agent.id if agent else None), vars=vars))
    await db_session.flush()


async def test_precedence_group_ou_host(db_session):
    root = await _ou(db_session, "DB")
    child = await _ou(db_session, "Prod", parent=root)
    agent = await _agent(db_session, child)
    grp = HostGroup(id=uuid4(), tenant_id=TENANT, name=f"g-{_sfx()}")
    db_session.add(grp)
    await db_session.flush()
    db_session.add(HostGroupMember(id=uuid4(), tenant_id=TENANT, host_group_id=grp.id, agent_id=agent.id))

    await _vars(db_session, "group", {"port": 1, "user": "grp", "region": "eu"}, group=grp)
    await _vars(db_session, "ou", {"user": "ou", "region": "eu-root"}, ou=root)       # stronger than group
    await _vars(db_session, "ou", {"region": "eu-prod"}, ou=child)                    # deeper OU stronger
    await _vars(db_session, "host", {"user": "host"}, agent=agent)                    # strongest
    await db_session.flush()

    merged = await resolve_scope_vars(db_session, agent)
    assert merged == {"port": 1, "user": "host", "region": "eu-prod"}


async def test_only_reaching_scopes(db_session):
    other_ou = await _ou(db_session, "Web")
    agent = await _agent(db_session, ou=None)
    await _vars(db_session, "ou", {"x": "1"}, ou=other_ou)     # unrelated OU
    await db_session.flush()
    assert await resolve_scope_vars(db_session, agent) == {}


# --- secret (vaulted) scope vars -------------------------------------------

from bossman.api.runbooks import _mask_vars  # noqa: E402
from bossman.services.vault import Vault  # noqa: E402


def test_mask_vars_masks_only_encrypted():
    v = Vault(key="", key_path="/tmp/claude-vault-test.key")
    stored = {"plain": "hello", "db_pw": v.encrypt("s3cr3t")}
    display, secret_keys = _mask_vars(stored)
    assert display["plain"] == "hello"
    assert display["db_pw"] == Vault.mask()
    assert secret_keys == ["db_pw"]
    assert "s3cr3t" not in str(display)


async def test_resolve_keeps_secret_encrypted_until_decrypt(db_session):
    """resolve_scope_vars returns the stored (encrypted) value verbatim; only
    the run-time decrypt step (runbook_exec) turns it back into plaintext."""
    v = Vault(key="", key_path="/tmp/claude-vault-test.key")
    agent = await _agent(db_session)
    await _vars(db_session, "host", {"api_key": v.encrypt("k-123")}, agent=agent)
    merged = await resolve_scope_vars(db_session, agent)
    assert Vault.is_encrypted(merged["api_key"])          # still encrypted at this layer
    assert merged["api_key"] != "k-123"
    assert v.decrypt(merged["api_key"]) == "k-123"        # run-time decrypt recovers it
