"""parameterize_snmp_star rewrites a translated SNMP check's hardcoded
`snmpwalk -c public localhost` argv so target + credentials come from the check's
params — supporting both v2c and v3 (SNMPv3 backlog item)."""

from bossman.services.monitoring import parameterize_snmp_star

STAR = (
    "def main(ctx, params):\n"
    '    out = ctx.run(["snmpwalk", "-c", "public", "localhost", "1.3.6.1.2.1.1.1.0"])\n'
    "    return struct(rc=out.rc)\n"
)


def test_v2c_backcompat_and_shape():
    got = parameterize_snmp_star(STAR)
    # argv literal is rewritten to concat around the computed _snmp_conn list.
    assert '["snmpwalk"] + _snmp_conn + ["1.3.6.1.2.1.1.1.0"]' in got
    # the preamble computes both branches; v2c is the default and unchanged.
    assert '_snmp_version = params.get("snmp_version", "v2c")' in got
    assert '_snmp_conn = ["-c", params.get("community", "public"), _snmp_target]' in got
    # v3 branch present with the USM flags gated by security level.
    assert '["-v3", "-l", _snmp_level, "-u", params.get("sec_name", "")]' in got
    assert '"-a", params.get("auth_proto", "SHA")' in got
    assert '"-x", params.get("priv_proto", "AES")' in got


def test_idempotent():
    once = parameterize_snmp_star(STAR)
    assert parameterize_snmp_star(once) == once  # already parameterized → no-op


def test_non_snmp_untouched():
    plain = 'def main(ctx, params):\n    return ctx.run(["cat", "/etc/hostname"])\n'
    assert parameterize_snmp_star(plain) == plain


def test_snmpget_form_also_handled():
    star = (
        "def main(ctx, params):\n"
        '    return ctx.run(["snmpget", "-c", "public", "127.0.0.1", "1.3.6.1.2.1.1.5.0"])\n'
    )
    got = parameterize_snmp_star(star)
    assert '["snmpget"] + _snmp_conn + ["1.3.6.1.2.1.1.5.0"]' in got
