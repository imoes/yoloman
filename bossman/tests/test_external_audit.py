"""Parser for out-of-band (auditd) change events — the fragile, version-sensitive
bit of external_audit, kept on the server so it is unit-tested here rather than
in an on-host shell script we can't exercise."""

from bossman.services import external_audit as ea

# Two real-shaped ausearch events: root editing nginx.conf with vim, and a
# daemon (auid unset) touching a sysctl file. Block form with `----` + time->.
RAW = """----
time->Mon Feb 02 12:00:00 2026
type=PROCTITLE msg=audit(1770034800.123:4711): proctitle=76696D002F6574632F6E67696E78
type=PATH msg=audit(1770034800.123:4711): item=1 name="/etc/nginx/nginx.conf" inode=1234 mode=0100644
type=CWD msg=audit(1770034800.123:4711): cwd="/root"
type=SYSCALL msg=audit(1770034800.123:4711): arch=c000003e syscall=257 success=yes exit=3 auid=1000 uid=0 gid=0 comm="vim" exe="/usr/bin/vim" key="bossman"
----
time->Mon Feb 02 12:05:00 2026
type=PATH msg=audit(1770035100.500:4712): item=0 name="/etc/sysctl.d/99-x.conf" inode=99 mode=0100644
type=SYSCALL msg=audit(1770035100.500:4712): arch=c000003e syscall=82 success=yes auid=4294967295 uid=0 comm="systemd" exe="/usr/lib/systemd/systemd" key="bossman"
"""


def test_parse_ausearch_extracts_who_what_when():
    events = ea.parse_ausearch(RAW)
    assert len(events) == 2
    by_path = {e["path"]: e for e in events}

    nginx = by_path["/etc/nginx/nginx.conf"]
    assert nginx["auid"] == "1000"        # login uid = who
    assert nginx["exe"] == "/usr/bin/vim"  # the process
    assert nginx["comm"] == "vim"
    assert nginx["serial"] == "4711"
    # `at` derives from the audit epoch (1770034800), not the human time-> line.
    assert nginx["at"].startswith("2026-02-02T")

    sysctl = by_path["/etc/sysctl.d/99-x.conf"]
    # auid 4294967295 (unset) → normalised to None: a daemon, not a login user.
    assert sysctl["auid"] is None
    assert sysctl["exe"] == "/usr/lib/systemd/systemd"


def test_parse_ausearch_empty_is_no_events():
    assert ea.parse_ausearch("") == []
    assert ea.parse_ausearch("no audit records\n") == []


def test_build_rules_watches_each_managed_path_once():
    rules = ea.build_rules(["/etc/nginx/nginx.conf", "/etc/nginx/nginx.conf", " ", "/etc/hosts"])
    assert "-w /etc/nginx/nginx.conf -p wa -k bossman" in rules
    assert "-w /etc/hosts -p wa -k bossman" in rules
    # deduped: nginx.conf appears exactly once
    assert rules.count("/etc/nginx/nginx.conf") == 1
