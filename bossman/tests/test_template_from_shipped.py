"""template_from_shipped: directive fields named after the directive; defaults render the shipped file."""

import jinja2

from bossman.tools.template_from_shipped import build, snake

SHIPPED = """##  AuthservID (string)
##  Sets the "authserv-id" to use.
# AuthservID name

##  PidFile path
##  Specifies the path to a file that should be created.
PidFile /run/opendmarc/opendmarc.pid
acl a src 10.0.0.0/8
acl b src 192.168.0.0/16
#UMask 002
"""


def render(body, **v):
    return jinja2.Environment(keep_trailing_newline=True).from_string(body).render(**v)


def test_defaults_render_the_shipped_file_and_prose_stays_prose():
    body, schema = build(SHIPPED)
    assert render(body) == SHIPPED
    assert set(schema) == {"authserv_id", "pid_file", "umask"}   # not `sets`, not `specifies`; acl repeats


def test_set_values_become_live_lines():
    body, schema = build(SHIPPED, {"AuthservID"})
    out = render(body, authserv_id="mx1.example.test", pid_file="/run/x.pid")
    assert "\nAuthservID mx1.example.test\n" in out and "\nPidFile /run/x.pid\n" in out
    assert schema["authserv_id"]["required"] is True and schema["pid_file"]["default"] == "/run/opendmarc/opendmarc.pid"


def test_field_names_follow_the_directive():
    assert [snake(k) for k in ("TrustedAuthservIDs", "UMask", "HTTPPort", "http_port")] == \
        ["trusted_authserv_ids", "umask", "http_port", "http_port"]
