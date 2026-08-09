# Starlark translation of checkmk.audiocodes_fru
# FRU status check for AudioCodes devices (SNMP-based).

ACTION_MAPPING = {
    "0": ("Invalid action", "UNKNOWN"),
    "1": ("Action done", "OK"),
    "2": ("Out of service", "WARN"),
    "3": ("Back to service", "OK"),
    "4": ("Not applicable", "OK"),
}

STATUS_MAPPING = {
    "0": ("Invalid status", "UNKNOWN"),
    "1": ("Module doesn't exist", "OK"),
    "2": ("Module exists and ok", "OK"),
    "3": ("Module Ouf of service", "CRIT"),
    "4": ("Module Back to service start", "OK"),
    "5": ("Module mismatch", "CRIT"),
    "6": ("Module faulty", "CRIT"),
    "7": ("Not applicable", "OK"),
}

FRU_TABLE_BASE = ".1.3.6.1.4.1.5003.9.10.10.4.21.1"
NAME_TABLE_BASE = ".1.3.6.1.4.1.5003.9.10.10.4.21"
NAME_COL_OID = NAME_TABLE_BASE + ".2"
ACTION_COL_OID = FRU_TABLE_BASE + ".13"
STATUS_COL_OID = FRU_TABLE_BASE + ".14"
ENTITY_OID = FRU_TABLE_BASE + ".1"


def _strip_type_tag(value):
    if not value:
        return ""
    idx = value.find(": ")
    if idx != -1 and value[:idx].replace(" ", "").isalpha():
        return value[idx + 2:]
    return value


def _clean(value):
    v = _strip_type_tag(value)
    if v.startswith('"') and v.endswith('"') and len(v) >= 2:
        v = v[1:-1]
    return v


def _get_snmp_value(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return _clean(res.stdout.strip())


def _walk_table(ctx, community, host, column_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        rows.append((oid, val))
    return rows


def _build_name_map(ctx, community, host):
    rows = _walk_table(ctx, community, host, NAME_COL_OID)
    names = {}
    for oid, val in rows:
        idx = oid[len(NAME_COL_OID) + 1:]
        if idx == "":
            continue
        names[idx] = _clean(val)
    return names


def _build_fru_map(ctx, community, host):
    rows = _walk_table(ctx, community, host, ENTITY_OID)
    fru = {}
    for oid, idx_val in rows:
        idx = oid[len(ENTITY_OID) + 1:]
        if idx == "":
            continue
        action_code = _get_snmp_value(ctx, community, host, ACTION_COL_OID + "." + idx)
        status_code = _get_snmp_value(ctx, community, host, STATUS_COL_OID + "." + idx)
        if action_code == None or status_code == None:
            continue
        fru[idx] = (action_code, status_code)
    return fru


def _probe_device(ctx, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ENTITY_OID + ".1"],
        mutates=False,
    )
    return res.rc == 0


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        if not _probe_device(ctx, community, host):
            return {
                "changed": False,
                "msg": "not an AudioCodes device (no SNMP response on FRU table)",
                "data": {"discovery": []},
            }
        names = _build_name_map(ctx, community, host)
        fru = _build_fru_map(ctx, community, host)
        discovery = []
        for idx, name in names.items():
            if idx not in fru:
                continue
            display = name if name != "" else idx
            discovery.append({"item": display, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d FRU modules" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not _probe_device(ctx, community, host):
        return {
            "changed": False,
            "msg": "not an AudioCodes device (no SNMP response on FRU table)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    names = _build_name_map(ctx, community, host)
    fru = _build_fru_map(ctx, community, host)

    target_idx = None
    if item in fru:
        target_idx = item
    else:
        for idx, name in names.items():
            if name == item and idx in fru:
                target_idx = idx
                break

    if target_idx == None:
        return {
            "changed": False,
            "msg": "FRU module not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    action_code, status_code = fru[target_idx]
    action = ACTION_MAPPING.get(action_code, ("Unknown action", "UNKNOWN"))
    status = STATUS_MAPPING.get(status_code, ("Unknown status", "UNKNOWN"))

    states = [action[1], status[1]]
    if "CRIT" in states:
        overall = "CRIT"
    elif "WARN" in states:
        overall = "WARN"
    elif "UNKNOWN" in states:
        overall = "UNKNOWN"
    else:
        overall = "OK"

    msg = item + ": Action: " + action[0] + ", Status: " + status[0]
    detail = "Action: " + action[0] + "\nStatus: " + status[0]

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": overall, "metrics": {}, "details": detail},
    }