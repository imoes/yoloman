# ===== Starlark translation of Checkmk check: akcp_exp_drycontact =====
# Dry Contact sensor check for AKCP expansion units, translated from the
# Checkmk SNMP-based check plugin to run on the yolo-man agent.

# AKCP EXP enterprise OID prefix and sensor table used for detection and
# discovery. The dry-contact sensor table lives under the SPAGENT-MIB
# enterprise subtree ".1.3.6.1.4.1.3854".
AKCP_SYS_OID = ".1.3.6.1.2.1.1.2.0"
AKCP_ENTERPRISE_BASE = ".1.3.6.1.4.1.3854"

# Column OIDs under the dry-contact sensor subtree (.1.3.6.1.4.1.3854.2.3.4.1):
#   2  = description
#   6  = status
#   46 = critical description
#   48 = normal description
#   8  = online
DC_BASE = ".1.3.6.1.4.1.3854.2.3.4.1"
DC_DESC = DC_BASE + ".2"
DC_STATUS = DC_BASE + ".6"
DC_CRIT = DC_BASE + ".46"
DC_NORMAL = DC_BASE + ".48"
DC_ONLINE = DC_BASE + ".8"

# States which are not configurable by user as defined in SPAGENT-MIB.
AKCP_DC_STATES = {
    "1": (2, "no status"),
    "7": (2, "sensor error"),
    "8": (2, "output low"),
    "9": (2, "output high"),
}


def _is_akcp_exp(ctx, params):
    """Detect an AKCP EXP device via the sysObjectID prefix and presence of
    the enterprise subtree. rc == 127 means the tool is not installed."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sys_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, AKCP_SYS_OID],
        mutates=False,
    )
    if sys_res.rc == 127:
        return False
    if sys_res.rc != 0:
        return False
    if not sys_res.stdout.strip():
        return False
    sys_oid = sys_res.stdout.strip()
    if not sys_oid.startswith(AKCP_ENTERPRISE_BASE + ".1"):
        return False
    # Require at least one entry beneath the enterprise subtree to exist.
    walk_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, AKCP_ENTERPRISE_BASE],
        mutates=False,
    )
    if walk_res.rc == 127:
        return False
    if walk_res.rc != 0:
        return False
    if not walk_res.stdout.strip():
        return False
    return True


def _snmp_build_table(ctx, params, column_oid):
    """Walk a single column OID with -Oqn/-On. Returns a list of
    (index, value) tuples where index is the OID suffix after the column
    base."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, column_oid],
        mutates=False,
    )
    if res.rc == 127 or res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        # Format: "<full-column-oid>.<index> <value>"
        sp = stripped.split(" ", 1)
        if len(sp) != 2:
            continue
        oid = sp[0]
        value = sp[1].strip()
        # Index is the OID suffix after the column base (including the dot).
        suffix = oid[len(column_oid):]
        index = suffix[1:] if suffix.startswith(".") else suffix
        rows.append((index, value))
    return rows


def _snmp_get_one(ctx, params, full_oid):
    """Read a single scalar value via snmpget -Oqv (bare value)."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, full_oid],
        mutates=False,
    )
    if res.rc == 127 or res.rc != 0:
        return None
    return res.stdout.strip()


def _parse_value(v):
    """Best-effort conversion of an SNMP string value, stripping type tags
    and surrounding quotes left by some snmp tools."""
    if v == None:
        return v
    s = v.strip()
    # Strip a leading "TYPE: " prefix if present (e.g. "STRING: " or
    # "INTEGER: ").
    colon = s.find(":")
    if colon != -1:
        rest = s[colon + 1:].strip()
        if rest:
            s = rest
    # Strip surrounding quotes.
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    return s


def _build_section(ctx, params):
    """Reconstruct the Checkmk StringTable for the dry-contact check by
    correlating the description, status, critical-desc, normal-desc and
    online columns via their shared index."""
    desc_rows = _snmp_build_table(ctx, params, DC_DESC)
    if not desc_rows:
        return []
    # Index -> [description, status, crit_desc, normal_desc, online]
    table = {}
    order = []
    for idx, val in desc_rows:
        desc = _parse_value(val)
        if desc == "":
            desc = idx
        table[idx] = [desc, None, None, None, None]
        order.append(idx)
    for col_oid, col_pos in [
        (DC_STATUS, 1), (DC_CRIT, 2), (DC_NORMAL, 3), (DC_ONLINE, 4),
    ]:
        for idx, val in _snmp_build_table(ctx, params, col_oid):
            if idx in table:
                table[idx][col_pos] = _parse_value(val)
    result = []
    for idx in order:
        result.append(table[idx])
    return result


def _grade_drycontact(line, item):
    """Apply the dry-contact check logic for a single matching line and
    return (state, summary). state is one of OK/WARN/CRIT/UNKNOWN."""
    # line layout: [description, status, crit_desc, normal_desc, online]
    if len(line) == 5:
        status, crit_desc, normal_desc, online = line[1:]
    else:
        status, online = line[1:3]
        normal_desc = "Drycontact OK"
        crit_desc = "Drycontact on Error"
    if online != "1":
        return ("CRIT", "Sensor is offline")
    if status == "2":
        return ("OK", normal_desc)
    if status in ("4", "6"):
        return ("CRIT", crit_desc)
    if status in AKCP_DC_STATES:
        code, name = AKCP_DC_STATES[status]
        if code == 0:
            return ("OK", name)
        if code == 1:
            return ("WARN", name)
        return ("CRIT", name)
    return ("UNKNOWN", "State: " + str(status) + " (" + item + ")")


def main(ctx, params):
    if not _is_akcp_exp(ctx, params):
        return {
            "changed": False,
            "msg": "no AKCP EXP device detected",
            "data": {"discovery": [], "host_labels": {}},
        }

    if params.get("_discover"):
        section = _build_section(ctx, params)
        discovery = []
        for line in section:
            # Online is the last element; "1" means online.
            if len(line) >= 5 and line[4] == "1":
                item = line[0]
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": [],
                })
            elif len(line) < 5 and line[-1] == "1":
                item = line[0]
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {
                "discovery": discovery,
                "host_labels": {"cmk/akcp_exp": "present"},
            },
        }

    item = params.get("item", "")
    section = _build_section(ctx, params)
    matched = None
    for line in section:
        if line[0] == item:
            matched = line
            break
    if matched == None:
        return {
            "changed": False,
            "msg": "no such dry contact sensor: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    state, summary = _grade_drycontact(matched, item)
    return {
        "changed": False,
        "msg": "Dry Contact %s: %s" % (item, summary),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }