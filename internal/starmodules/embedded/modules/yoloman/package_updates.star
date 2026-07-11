# yoloman.package_updates — list + apply OS package updates, independent of
# the package manager (apt on Debian/Ubuntu, dnf/yum on RHEL-family). This is
# Cockpit's "Software updates" page mapped onto our agent: state=list reports
# the pending updates (with a security count and whether a reboot is needed);
# state=apply installs them (all, or security-only). Mutating steps are
# mutates=True so the runtime enforces check_mode + the write gate. Contract
# shape: {changed, msg, data}.

def main(ctx, params):
    state = params.get("state", "list")
    if state not in ("list", "apply"):
        fail("state must be one of: list, apply")
    mgr = params.get("manager") or _detect_manager(ctx)
    if mgr == "apt":
        return _apt(ctx, params, state)
    if mgr in ("dnf", "yum"):
        return _dnf(ctx, params, state, mgr)
    fail("no supported package manager detected (looked for apt, dnf, yum)")


def _cmd_exists(ctx, cmd):
    return ctx.run(["sh", "-c", "command -v %s" % cmd], mutates=False).rc == 0


def _detect_manager(ctx):
    if _cmd_exists(ctx, "apt-get"):
        return "apt"
    if _cmd_exists(ctx, "dnf"):
        return "dnf"
    if _cmd_exists(ctx, "yum"):
        return "yum"
    return "unknown"


# ---- apt (Debian / Ubuntu) ------------------------------------------------

def _apt(ctx, params, state):
    if state == "apply":
        return _apt_apply(ctx, params)

    # refresh the package index first (mutates the apt cache, not the system)
    if params.get("refresh", True):
        ctx.run(["apt-get", "update", "-q"], mutates=True)

    res = ctx.run(["apt-get", "--just-print", "upgrade"], mutates=False)
    updates = _parse_apt_upgrade(res.stdout)
    _apt_attach_sources(ctx, updates)
    security = _apt_security_count(ctx)
    return {
        "changed": False,
        "msg": "%d update(s) available" % len(updates),
        "data": {
            "manager": "apt",
            "updates": updates,
            "count": len(updates),
            "security_count": security,
            "reboot_required": ctx.file_exists("/var/run/reboot-required"),
        },
    }


# _parse_apt_upgrade reads `apt-get --just-print upgrade` "Inst" lines:
#   Inst libc6 [2.31-13] (2.31-13+deb11u5 Debian:11/stable [amd64])
def _parse_apt_upgrade(out):
    updates = []
    for line in out.split("\n"):
        line = line.strip()
        if not line.startswith("Inst "):
            continue
        toks = line.split()
        if len(toks) < 2:
            continue
        name = toks[1]
        current = ""
        candidate = ""
        if len(toks) >= 3 and toks[2].startswith("["):
            current = toks[2].strip("[]")
        if "(" in line:
            after = line.split("(", 1)[1]
            cand_toks = after.split()
            if cand_toks:
                candidate = cand_toks[0]
        security = "security" in line.lower()
        updates.append({"name": name, "current": current, "candidate": candidate, "security": security, "source": name})
    return updates


# _apt_attach_sources fills each update's source (binary→source) package — the
# key the Debian Security Tracker / Ubuntu USN feeds are indexed by. One
# dpkg-query call builds the whole map; source is blank when it equals the
# binary name, so we keep the name as the fallback.
def _apt_attach_sources(ctx, updates):
    if not updates:
        return
    res = ctx.run(["dpkg-query", "-W", "-f=${Package} ${source:Package}\n"], mutates=False)
    if res.rc != 0:
        return
    src = {}
    for line in res.stdout.split("\n"):
        toks = line.split()
        if len(toks) >= 2:
            src[toks[0]] = toks[1]
        elif len(toks) == 1:
            src[toks[0]] = toks[0]
    for u in updates:
        if u["name"] in src:
            u["source"] = src[u["name"]]


# _apt_security_count uses update-notifier's apt-check if present (the count
# Ubuntu's MOTD shows); otherwise falls back to the per-line security flag.
def _apt_security_count(ctx):
    checker = "/usr/lib/update-notifier/apt-check"
    if ctx.file_exists(checker):
        # apt-check prints "<updates>;<security>" on stderr
        res = ctx.run([checker], mutates=False)
        text = res.stderr.strip() or res.stdout.strip()
        parts = text.split(";")
        if len(parts) == 2 and parts[1].strip().isdigit():
            return int(parts[1].strip())
    return -1  # unknown


def _apt_apply(ctx, params):
    security_only = params.get("security_only", False)
    if security_only and _cmd_exists(ctx, "unattended-upgrade"):
        res = ctx.run(["unattended-upgrade", "-v"], mutates=True)
        ok = res.rc == 0
        return {
            "changed": ok and not res.skipped,
            "msg": "applied security updates via unattended-upgrade" if ok else "unattended-upgrade failed",
            "data": {"manager": "apt", "security_only": True, "rc": res.rc, "reboot_required": ctx.file_exists("/var/run/reboot-required")},
        }
    # full upgrade (DEBIAN_FRONTEND noninteractive so it never blocks on prompts)
    res = ctx.run(
        ["sh", "-c", "DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade"],
        mutates=True,
    )
    if res.rc != 0 and not res.skipped:
        fail("apt-get upgrade failed: %s" % (res.stderr or res.stdout))
    return {
        "changed": not res.skipped,
        "msg": "applied all updates via apt-get upgrade",
        "data": {"manager": "apt", "security_only": False, "rc": res.rc, "reboot_required": ctx.file_exists("/var/run/reboot-required")},
    }


# ---- dnf / yum (RHEL family) ----------------------------------------------

def _dnf(ctx, params, state, mgr):
    if state == "apply":
        return _dnf_apply(ctx, params, mgr)

    # check-update: rc 100 means updates are available, 0 means none
    res = ctx.run([mgr, "-q", "check-update"], mutates=False, ok_codes=[0, 100])
    updates = _parse_dnf_checkupdate(res.stdout)
    _dnf_attach_cves(ctx, mgr, updates)
    security = _dnf_security_count(ctx, mgr)
    return {
        "changed": False,
        "msg": "%d update(s) available" % len(updates),
        "data": {
            "manager": mgr,
            "updates": updates,
            "count": len(updates),
            "security_count": security,
            "reboot_required": _dnf_reboot_required(ctx),
        },
    }


# _parse_dnf_checkupdate reads columns: "name.arch  version  repo"
def _parse_dnf_checkupdate(out):
    updates = []
    for line in out.split("\n"):
        line = line.rstrip()
        if not line.strip():
            continue
        # skip obsoleting section + headers
        if line.startswith("Obsoleting") or line.startswith("Last metadata"):
            continue
        toks = line.split()
        if len(toks) < 3:
            continue
        name = toks[0]
        candidate = toks[1]
        # ignore lines that don't look like a package row
        if "." not in name:
            continue
        updates.append({"name": name, "current": "", "candidate": candidate, "security": False, "cves": [], "severity": ""})
    return updates


# _dnf_attach_cves maps `dnf updateinfo list cves` onto the update list. Lines
# look like: "CVE-2024-1234 Important/Sec. openssl-1.2-3.el9.x86_64". We match
# a CVE to an update when the advisory's nevra starts with the update's base
# package name, and flag the update as a security update.
def _dnf_attach_cves(ctx, mgr, updates):
    if not updates:
        return
    res = ctx.run([mgr, "-q", "updateinfo", "list", "cves"], mutates=False, ok_codes=[0, 100])
    rows = []  # (cve, severity, nevra)
    for line in res.stdout.split("\n"):
        toks = line.split()
        if len(toks) < 3 or not toks[0].startswith("CVE-"):
            continue
        sev = toks[1].split("/")[0]
        rows.append((toks[0], sev, toks[2]))
    for u in updates:
        base = u["name"].rsplit(".", 1)[0]  # drop the .arch suffix
        cves = []
        sev = ""
        for cve, s, nevra in rows:
            if nevra.startswith(base + "-"):
                if cve not in cves:
                    cves.append(cve)
                if not sev:
                    sev = s
        if cves:
            u["cves"] = cves
            u["severity"] = sev
            u["security"] = True


def _dnf_security_count(ctx, mgr):
    res = ctx.run([mgr, "-q", "updateinfo", "list", "security"], mutates=False, ok_codes=[0, 100])
    n = 0
    for line in res.stdout.split("\n"):
        if line.strip():
            n += 1
    return n


def _dnf_reboot_required(ctx):
    if _cmd_exists(ctx, "needs-restarting"):
        # needs-restarting -r: rc 1 -> reboot required, 0 -> not
        res = ctx.run(["needs-restarting", "-r"], mutates=False, ok_codes=[0, 1])
        return res.rc == 1
    return False


def _dnf_apply(ctx, params, mgr):
    security_only = params.get("security_only", False)
    cmd = [mgr, "-y", "upgrade"]
    if security_only:
        cmd.append("--security")
    res = ctx.run(cmd, mutates=True)
    if res.rc != 0 and not res.skipped:
        fail("%s upgrade failed: %s" % (mgr, res.stderr or res.stdout))
    return {
        "changed": not res.skipped,
        "msg": "applied %s updates via %s" % ("security" if security_only else "all", mgr),
        "data": {"manager": mgr, "security_only": security_only, "rc": res.rc, "reboot_required": _dnf_reboot_required(ctx)},
    }
