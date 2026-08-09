"""Pure unit tests for the shared scope matcher (Block N1) — no DB."""

from bossman.services.scope import HostCtx, Scope, ServiceCtx, scope_covers

HOST = HostCtx(
    name="vpp0221.example.com",
    groups=["Europe/Latvia", "docker-hosts"],
    ou_ids=frozenset({"ou-root", "ou-munich", "ou-prod"}),
)
SVC = ServiceCtx(service_name="Memory", policy_ids=frozenset({"plan-web", "plan-base"}))


def _s(**kw):
    return Scope(**kw)


def test_global_covers_everything():
    assert scope_covers(_s(scope_type="global"), HOST, SVC)


def test_ou_covers_ancestor_only():
    assert scope_covers(_s(scope_type="ou", ou_id="ou-munich"), HOST, SVC)
    assert not scope_covers(_s(scope_type="ou", ou_id="ou-other"), HOST, SVC)


def test_group_exact_and_nested():
    assert scope_covers(_s(scope_type="group", value="docker-hosts"), HOST, SVC)
    # A parent group covers a host in a nested child group.
    assert scope_covers(_s(scope_type="group", value="Europe"), HOST, SVC)
    assert not scope_covers(_s(scope_type="group", value="Asia"), HOST, SVC)


def test_host_exact():
    assert scope_covers(_s(scope_type="host", value="vpp0221.example.com"), HOST, SVC)
    assert not scope_covers(_s(scope_type="host", value="vpp0222.example.com"), HOST, SVC)


def test_service_needs_both_host_and_service():
    assert scope_covers(_s(scope_type="service", value="vpp0221.example.com", service_name="Memory"), HOST, SVC)
    # Right host, wrong service → no.
    assert not scope_covers(_s(scope_type="service", value="vpp0221.example.com", service_name="CPU load"), HOST, SVC)
    # Right service, wrong host → no.
    assert not scope_covers(_s(scope_type="service", value="other-host", service_name="Memory"), HOST, SVC)


def test_policy_membership():
    assert scope_covers(_s(scope_type="policy", plan_id="plan-web"), HOST, SVC)
    assert not scope_covers(_s(scope_type="policy", plan_id="plan-db"), HOST, SVC)


def test_unknown_scope_never_covers():
    assert not scope_covers(_s(scope_type="bogus"), HOST, SVC)
