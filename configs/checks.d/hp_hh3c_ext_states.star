# hp_hh3c_ext_states — translated from Checkmk check plugin
# Monitors HH3C entity administrative/operational states via SNMP.

ADMIN_STATES = {
    "1": ("WARN", "not_supported", "not supported"),
    "2": ("OK", "locked", "locked"),
    "3": ("CRIT", "shutting_down", "shutting down"),
    "4": ("CRIT", "unlocked", "unlocked"),
}

OPER_STATES = {
    "1": ("WARN", "not_supported", "not supported"),
    "2": ("CRIT", "disabled", "disabled"),
    "3": ("OK", "enabled", "enabled"),
    "4": ("CRIT", "dangerous", "dangerous"),
}


def _strip_type(s):
    # Remove leading "<TYPE>: " and surrounding quotes from a scalar value.
    idx = s.find(": ")
    if idx == -1:
        v = s
    else:
        v = s[idx + 2:]
    v = v.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1]
    elif len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        v = v[1:-1]
    return v


def _snmpget(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmpwalk(ctx, community, host, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        out.append((parts[0], parts[1]))
    return out


def _fetch_section(ctx, community, host):
    """Fetch and parse the hp_hh3c_ext section from SNMP. Returns list of dicts."""
    base1 = ".1.3.6.1.4.1.25506.2.6.1.1.1.1"
    base2 = ".1.3.6.1.2.1.47.1.1.1.1"
    sysid = _snmpget(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
    if sysid == None:
        return None
    # detect: sysObjectID must start with one of the HH3C prefixes
    valid = False
    for prefix in [
        ".1.3.6.1.4.1.25506.11.1.239",
        ".1.3.6.1.4.1.25506.11.1.189",
        ".1.3.6.1.4.1.25506.11.1.87",
    ]:
        if sysid.startswith(prefix):
            valid = True
            break
    if not valid:
        return None

    col_index = base1 + ".1"
    col_admin = base1 + ".2"
    col_oper = base1 + ".3"
    col_cpu = base1 + ".6"
    col_mem_usage = base1 + ".8"
    col_mem_size = base1 + ".12"
    col_temp = base1 + ".10"
    ent_name_col = base2 + ".3"  # entPhysicalName

    rows = _snmpwalk(ctx, community, host, col_index)
    if not rows:
        return None

    entity_info = {}
    for oid, val in _snmpwalk(ctx, community, host, ent_name_col):
        entity_info[oid] = _strip_type(val)

    result = []
    for oid, _ in rows:
        index = oid[len(col_index) + 1:]
        mem_size_raw = _snmpget(ctx, community, host, col_mem_size + "." + index)
        if mem_size_raw == None:
            continue
        mem_total = int(mem_size_raw)
        if mem_total <= 0:
            continue

        name = entity_info.get(oid[len(base2) + 1:], "")
        item_name = (name + " " + index).strip()

        admin_raw = _snmpget(ctx, community, host, col_admin + "." + index) or "1"
        oper_raw = _snmpget(ctx, community, host, col_oper + "." + index) or "1"

        result.append({
            "item": item_name,
            "admin": admin_raw,
            "oper": oper_raw,
            "mem_total": mem_total,
        })
    return result


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        data = _fetch_section(ctx, community, host)
        if data == None:
            return {"changed": False, "msg": "no HH3C device detected", "data": {"discovery": []}}
        discovery = []
        for entry in data:
            discovery.append({
                "item": entry["item"],
                "params": {},
                "metrics": ["state"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    data = _fetch_section(ctx, community, host)
    if data == None:
        return {
            "changed": False,
            "msg": "no HH3C device detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    found = None
    for entry in data:
        if entry["item"] == item:
            found = entry
            break
    if found == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    admin_overrides = params.get("admin", {})
    oper_overrides = params.get("oper", {})
    overall_state = "OK"
    summaries = []

    for label, raw_state, mapping, overrides in (
        ("Administrative", found["admin"], ADMIN_STATES, admin_overrides),
        ("Operational", found["oper"], OPER_STATES, oper_overrides),
    ):
        if raw_state in mapping:
            default_state, params_key, readable = mapping[raw_state]
        else:
            default_state, params_key, readable = ("UNKNOWN", "unknown", "unknown[" + raw_state + "]")
        state = default_state
        if params_key in overrides:
            state = overrides[params_key]
            # overrides store state as string name
            if type(state) == "int":
                if state == 1:
                    state = "WARN"
                elif state in (2, 3):
                    state = "OK" if state == 2 else "CRIT"
                else:
                    state = "UNKNOWN"
        summaries.append(label + ": " + readable + " (" + state + ")")
        if state == "CRIT":
            overall_state = "CRIT"
        elif state == "WARN" and overall_state != "CRIT":
            overall_state = "WARN"
        elif state == "UNKNOWN" and overall_state in ("OK",):
            overall_state = "UNKNOWN"

    return {
        "changed": False,
        "msg": ", ".join(summaries),
        "data": {
            "state": overall_state,
            "metrics": {},
            "details": ", ".join(summaries),
        },
    }