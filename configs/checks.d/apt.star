def _parse_line(line):
    sp = line.split(" ", 1)
    if len(sp) < 2:
        return None
    action = sp[0]
    if action != "Inst" and action != "Remv":
        return None
    rest = sp[1]
    pkg_sp = rest.split(" ", 1)
    package = pkg_sp[0]
    rest = pkg_sp[1] if len(pkg_sp) > 1 else ""
    old_version = None
    update_metadata = None
    if rest.startswith("["):
        close = rest.find("]")
        if close == -1:
            return None
        old_version = rest[1:close].strip()
        rest = rest[close + 1:]
        if rest.startswith(" "):
            rest = rest[1:]
    if rest.startswith("("):
        close = rest.find(")")
        if close == -1:
            return None
        update_metadata = rest[1:close].strip()
        rest = rest[close + 1:]
    return {"action": action, "package": package, "old_version": old_version, "update_metadata": update_metadata}


def _is_security_update(update_metadata):
    if update_metadata == None:
        return False
    if "Debian-Security:" in update_metadata:
        return True
    if "Ubuntu" in update_metadata:
        idx = update_metadata.find("Ubuntu")
        after = update_metadata[idx + 6:]
        slash_idx = after.find("/")
        if slash_idx != -1:
            after_slash = after[slash_idx + 1:]
            if "-security" in after_slash:
                return True
    return False


NOTHING_PENDING = "No updates pending for installation"
ESM_NOT_ENABLED = "Enable UA Infra"
ESM_ENABLED = "ESM service enabled"
UBUNTU_PRO = "Ubuntu Pro"


def _sanitize(string_table):
    sanitized = []
    i = 0
    n = len(string_table)
    while i < n:
        row = string_table[i]
        line = row[0] if len(row) > 0 else ""
        if UBUNTU_PRO in line:
            i = i + 2
        elif ESM_ENABLED in line:
            i = i + 4
        else:
            sanitized.append(row)
            i = i + 1
    return sanitized


def _data_is_valid(string_table):
    if len(string_table) == 0:
        return False
    first_row = string_table[0]
    if len(first_row) != 1:
        return False
    first_line = first_row[0]
    if first_line == NOTHING_PENDING:
        return True
    if "security update" in first_line:
        if len(string_table) < 2:
            return False
        first_row = string_table[1]
        first_line = first_row[0] if len(first_row) > 0 else ""
    parts = _parse_line(first_line)
    if parts == None:
        return False
    return parts["old_version"] != None or parts["update_metadata"] != None


def _gather_raw(ctx):
    res = ctx.run(["apt-get", "upgrade", "--simulate", "-q", "-q"], mutates=False)
    if res.rc == 127:
        return None
    if not res.stdout:
        return {"rows": [], "have_output": False}
    rows = []
    for line in res.stdout.splitlines():
        rows.append([line])
    return {"rows": rows, "have_output": True}


def _parse_section(ctx):
    raw = _gather_raw(ctx)
    if raw == None:
        return None
    sanitized = _sanitize(raw["rows"])
    if len(sanitized) == 0:
        return {"updates": [], "removals": [], "sec_updates": [], "esm_support": True, "valid": True, "have_output": raw["have_output"]}
    first_line = sanitized[0][0] if len(sanitized[0]) > 0 else ""
    if first_line == NOTHING_PENDING:
        return {"updates": [], "removals": [], "sec_updates": [], "esm_support": True, "valid": True, "have_output": raw["have_output"]}
    if ESM_NOT_ENABLED in first_line:
        return {"updates": [], "removals": [], "sec_updates": [], "esm_support": False, "valid": True, "have_output": raw["have_output"]}
    if not _data_is_valid(sanitized):
        return {"updates": [], "removals": [], "sec_updates": [], "esm_support": True, "valid": False, "have_output": raw["have_output"]}
    updates = []
    removals = []
    sec_updates = []
    for row in sanitized:
        line = row[0]
        p = _parse_line(line)
        if p == None:
            continue
        if p["action"] == "Remv":
            removals.append(p["package"])
            continue
        if _is_security_update(p["update_metadata"]):
            sec_updates.append(p["package"])
            continue
        updates.append(p["package"])
    return {"updates": updates, "removals": removals, "sec_updates": sec_updates, "esm_support": True, "valid": True, "have_output": raw["have_output"]}


def _format_summary(action, packages, verbose):
    summary = "%d %s" % (len(packages), action)
    if verbose and len(packages) > 0:
        summary += " (%s)" % ", ".join(packages)
    return summary


def main(ctx, params):
    if params.get("_discover"):
        section = _parse_section(ctx)
        if section == None:
            return {"changed": False, "msg": "apt-get not found", "data": {"discovery": [], "host_labels": {}}}
        if section["valid"] == False:
            return {"changed": False, "msg": "no valid apt data", "data": {"discovery": [], "host_labels": {}}}
        if not section["have_output"] and len(section["updates"]) == 0 and len(section["removals"]) == 0 and len(section["sec_updates"]) == 0:
            return {"changed": False, "msg": "apt-get not found", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "discovered 1 item", "data": {
            "discovery": [{"item": "", "params": {"normal": 1, "removals": 1, "security": 2}, "metrics": ["normal_updates", "security_updates"]}],
            "host_labels": {"cmk/apt": "yes"},
        }}

    section = _parse_section(ctx)
    if section == None or section["valid"] == False:
        return {"changed": False, "msg": "no valid apt data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    normal = params.get("normal", 1)
    removals_p = params.get("removals", 1)
    security = params.get("security", 2)

    metrics = {"normal_updates": len(section["updates"]), "security_updates": len(section["sec_updates"])}

    if not section["esm_support"]:
        return {"changed": False, "msg": "System could receive security updates, but needs extended support license",
                "data": {"state": "CRIT", "metrics": metrics, "details": ""}}

    n_total = len(section["updates"]) + len(section["removals"]) + len(section["sec_updates"])
    if n_total == 0:
        return {"changed": False, "msg": NOTHING_PENDING,
                "data": {"state": "OK", "metrics": {"normal_updates": 0, "security_updates": 0}, "details": ""}}

    state = "OK"

    if len(section["updates"]) > 0:
        if int(normal) >= 2:
            state = "CRIT"
        elif int(normal) == 1 and state == "OK":
            state = "WARN"

    if len(section["removals"]) > 0:
        r_val = int(removals_p)
        if r_val >= 2:
            state = "CRIT"
        elif r_val == 1 and state == "OK":
            state = "WARN"
        metrics["removals"] = len(section["removals"])

    if len(section["sec_updates"]) > 0:
        s_val = int(security)
        if s_val >= 2:
            state = "CRIT"
        elif s_val == 1 and state == "OK":
            state = "WARN"

    parts = []
    parts.append(_format_summary("normal updates", section["updates"], False))
    if len(section["removals"]) > 0:
        parts.append(_format_summary("auto removals", section["removals"], True))
    if len(section["sec_updates"]) > 0:
        parts.append(_format_summary("security updates", section["sec_updates"], True))
    summary = ", ".join(parts)
    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": metrics, "details": ""}}