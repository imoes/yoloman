"""`mode` is an alias of `autonomy` — and the DIRECTION of its fallback is the point.

Until 2026-08-31 `mode: auto|propose` was validated strictly, stored, and read by nothing: the engine
gates on `autonomy` alone. Making it an alias is easy to get dangerously wrong, because `mode`
defaults to `"auto"` in the payload while `autonomy` defaults to `"propose"`. A naive alias would
therefore promote every rule that sends neither field from "suggest a fix" to "apply it unattended" —
silently, at scale, in the one direction a default must never fail in.

These are unit tests of the resolver rather than route tests: the resolver IS the decision, it is
pure, and testing it directly means the safety property is checked without a database.
"""

from bossman.api.remediation import RemediationPolicyIn, _mode_of, _resolve_autonomy


def _body(**kw) -> RemediationPolicyIn:
    """A payload carrying exactly the fields named — `model_fields_set` is what the resolver reads,
    so a helper that filled in defaults would test nothing."""
    return RemediationPolicyIn(name="r", **kw)


# ── the safety property, first ──────────────────────────────────────────────────────────────────

def test_neither_field_sent_stays_propose():
    """THE regression this file exists for. `mode` defaults to "auto"; if the resolver looked at the
    value rather than at whether it was sent, this would come back "auto_verify" and every existing
    rule would start acting on its own."""
    assert _resolve_autonomy(_body()) == "propose"


def test_defaulted_mode_does_not_escalate_even_when_autonomy_is_explicit():
    assert _resolve_autonomy(_body(autonomy="propose")) == "propose"


# ── the alias actually working ──────────────────────────────────────────────────────────────────

def test_mode_auto_alone_means_auto_verify():
    assert _resolve_autonomy(_body(mode="auto")) == "auto_verify"


def test_mode_propose_alone_means_propose():
    assert _resolve_autonomy(_body(mode="propose")) == "propose"


def test_autonomy_wins_when_both_are_sent():
    """The UI's own create form sends `mode: "auto"` beside `autonomy: "propose"`, so this pair must
    be accepted rather than refused — and it must resolve to what the real gate says."""
    assert _resolve_autonomy(_body(mode="auto", autonomy="propose")) == "propose"
    assert _resolve_autonomy(_body(mode="propose", autonomy="auto_verify")) == "auto_verify"


def test_unknown_mode_falls_back_to_the_safe_half():
    """Validation rejects an unknown `mode` at the route, but the resolver is also reachable from a
    stored row and from a future caller. Unknown must never read as "acts unattended"."""
    assert _resolve_autonomy(_body(mode="whatever")) == "propose"


# ── the response direction ──────────────────────────────────────────────────────────────────────

def test_mode_is_derived_from_autonomy_not_stored():
    assert _mode_of("auto_verify") == "auto"
    assert _mode_of("propose") == "propose"
    # A row from before the alias can hold any autonomy value; none of them may read as "auto".
    assert _mode_of("") == "propose"
    assert _mode_of("something_new") == "propose"
