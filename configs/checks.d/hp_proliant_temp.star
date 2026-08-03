# hp_proliant_temp.star — read-only Checkmk check (SNMP temperature) for yolo-man

HP_PROLIANT_LOCALE = {
    1: "other",
    2: "unknown",
    3: "system",
    4: "systemBoard",
    5: "ioBoard",
    6: "cpu",
    7: "memory",
    8: "storage",
    9: "removableMedia",
    10: "powerSupply",
    11: "ambient",
    12: "chassis",
    13: "bridgeCard",
    14: "managementBoard",
    15: "backplane",
    16: "networkSlot",
    17: "bladeSlot",
    18: "virtual",
}

HP_PROLIANT_STATUS_MAP = {
    1: "unknown",
    2: "ok",
    3: "degraded",
    4: "failed",
    5: "disabled",
}

DEV_STATUS_TO_STATE = {
    "ok": "OK",
    "unknown": "UNKNOWN",
    "other": "UNKNOWN",
    "degraded": "CRIT",
    "failed": "CRIT",
    "disabled": "WARN",
}

BASE_OID = ".1.3.6.1.4.1.232.6.2.6.8.1"
COL_NAME = "2"
COL_LOCALE = "3"
COL_VALUE = "4"
COL_THRESHOLD = "5"
COL_STATUS = "6"
PRODUCT_NAME_OID = ".1.3.6.1.4.1.232.2.2.4.2.0"


def _safe_int(s):
    return int(s) if (type(s) == "string" and s.isdigit()) else 0


def _format_name(name, locale_str):
    loc_int = _safe_int(locale_str)
    loc = HP_PROLIANT_LOCALE.get(loc_int, "unknown")
    return name + " (" + loc + ")"


def _strip_snmpval(val):
    v = val.strip()
    if ": " in v:
        v = v.split(": ", 1)[1]
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1]
    return v


def _detect(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", host, PRODUCT_NAME_OID],
        mutates=False,
    )
    if res.rc == 127 or res.rc != 0 or not res.stdout:
        return False
    val_lower = _strip_snmpval(res.stdout).lower()
    return ("proliant" in val_lower or "storeeasy" in val_lower or "synergy" in val_lower)


def _walk_table(ctx, params, col):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid = BASE_OID + "." + col
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    prefix = oid + "."
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp]
        val = line[sp + 1:]
        idx = full_oid[len(prefix):] if full_oid.startswith(prefix) else full_oid[len(oid):].lstrip(".")
        rows.append((idx, val))
    return rows


def _get_col(ctx, params, col, idx):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid = BASE_OID + "." + col + "." + idx
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", host, oid],
        mutates=False,
    )
    if res.rc == 127 or res.rc != 0 or not res.stdout:
        return ""
    return _strip_snmpval(res.stdout)


def _to_float(s):
    if not s or s == "N/A":
        return None
    neg = s.startswith("-")
    body = s[1:] if neg else s
    parts = body.split(".", 1)
    if len(parts) == 2:
        if not (parts[0].isdigit() and parts[1].isdigit()):
            return None
    elif not body.isdigit():
        return None
    return float(s)


def _lookup_rows(ctx, params, idx):
    name = _get_col(ctx, params, COL_NAME, idx)
    locale = _get_col(ctx, params, COL_LOCALE, idx)
    value = _get_col(ctx, params, COL_VALUE, idx)
    threshold = _get_col(ctx, params, COL_THRESHOLD, idx)
    status = _get_col(ctx, params, COL_STATUS, idx)
    return (name, locale, value, threshold, status)


def main(ctx, params):
    if not _detect(ctx, params):
        return {
            "changed": False,
            "msg": "HP ProLiant/StoreEasy/Synergy device not detected on " + params.get("host", "localhost"),
            "data": {"discovery": [], "host_labels": {}},
        }

    if params.get("_discover"):
        names = _walk_table(ctx, params, COL_NAME)
        discovery = []
        for idx, name in names:
            _, locale, _, _, status = _lookup_rows(ctx, params, idx)
            loc_int = _safe_int(locale)
            if loc_int == 1:
                continue
            st_int = _safe_int(status)
            if st_int == 1:
                continue
            item_name = _format_name(name, locale)
            discovery.append({
                "item": item_name,
                "params": {},
                "metrics": ["temperature"],
                "service_labels": {"hp_proliant_locale": HP_PROLIANT_LOCALE.get(loc_int, "unknown")},
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {"cmk/hp_proliant": "true"}},
        }

    item = params.get("item", "")
    warn = params.get("warn", 70)
    crit = params.get("crit", 80)
    levels = params.get("levels", None)
    if levels != None and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]

    names = _walk_table(ctx, params, COL_NAME)
    found_idx = None
    for idx, name in names:
        if _format_name(name, _get_col(ctx, params, COL_LOCALE, idx)) == item:
            found_idx = idx
            break

    if found_idx == None:
        return {
            "changed": False,
            "msg": "no such temperature sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value_str, threshold_str, status_str = _get_col(ctx, params, COL_VALUE, found_idx), "", ""
    _, _, _, threshold_str, status_str = _lookup_rows(ctx, params, found_idx)
    value_str = _get_col(ctx, params, COL_VALUE, found_idx)

    value_f = _to_float(value_str)
    if value_f == None:
        return {
            "changed": False,
            "msg": "no temperature value available for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    st_int = _safe_int(status_str)
    snmp_status = HP_PROLIANT_STATUS_MAP.get(st_int, "unknown")
    dev_state = DEV_STATUS_TO_STATE.get(snmp_status, "UNKNOWN")

    dev_levels = None
    if threshold_str not in ("-99", "0", "", "N/A"):
        thr_f = _to_float(threshold_str)
        if thr_f != None:
            dev_levels = (thr_f, thr_f)

    state = "OK"
    if dev_state == "CRIT":
        state = "CRIT"
    elif dev_state == "WARN":
        state = "WARN"
    elif dev_state == "UNKNOWN":
        state = "UNKNOWN"
    else:
        if value_f >= crit:
            state = "CRIT"
        elif value_f >= warn:
            state = "WARN"

    details = "Name: " + item + ", Value: %s C" % str(value_f) + ", Status: " + snmp_status
    if dev_levels != None:
        details = details + ", Dev threshold: %s C" % str(dev_levels[0])

    return {
        "changed": False,
        "msg": item + " " + str(value_f) + " C (status: " + snmp_status + ")",
        "data": {"state": state, "metrics": {"temperature": value_f}, "details": details},
    }