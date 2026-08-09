DKU_BASE = ".1.3.6.1.4.1.116.5.11.4.1.1.7.1"
DKU_OID_COLS = ["1", "2", "3", "4", "5"]
DKU_LABELS = ["Power Supply", "Fan", "Environment", "Drive"]

_HUS_MAP_STATES = {
    "0": ("UNKNOWN", "unknown"),
    "1": ("OK", "no error"),
    "2": ("CRIT", "acute"),
    "3": ("CRIT", "serious"),
    "4": ("WARN", "moderate"),
    "5": ("WARN", "service"),
}


def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", "-Ln", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpget binary not found on agent; is net-snmp installed?")
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val == "":
        return None
    return val


def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-Ln", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpwalk binary not found on agent; is net-snmp installed?")
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        rows.append((line[:sp], line[sp + 1:]))
    return rows


def _walk_full(ctx, host, community, column_oid):
    rows = _snmp_walk(ctx, host, community, column_oid)
    col_base = column_oid
    out = {}
    for oid, val in rows:
        if not oid.startswith(col_base + "."):
            continue
        idx = oid[len(col_base) + 1:]
        out[idx] = val
    return out


def _hus_detect(ctx, host, community):
    sys_descr = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.1.0")
    if sys_descr == None:
        return False
    for marker in ("hm700", "hm800", "hm850", "hm900"):
        if marker in sys_descr:
            return True
    return False


def _hus_state(code):
    mapped = _HUS_MAP_STATES.get(code)
    if mapped == None:
        return ("UNKNOWN", "unknown state code %s" % code)
    return mapped


def _read_dku_table(ctx, host, community):
    col1 = _walk_full(ctx, host, community, DKU_BASE + "." + DKU_OID_COLS[0])
    col4 = _walk_full(ctx, host, community, DKU_BASE + "." + DKU_OID_COLS[3])
    col5 = _walk_full(ctx, host, community, DKU_BASE + "." + DKU_OID_COLS[4])

    chassis_ids = set(col1.keys())
    chassis_ids.update(col4.keys())
    chassis_ids.update(col5.keys())

    table = {}
    for cid in chassis_ids:
        row = []
        for col_oid in DKU_OID_COLS:
            full_oid = DKU_BASE + "." + col_oid + "." + cid
            row.append(_snmp_get(ctx, host, community, full_oid))
        table[cid] = row
    return table


def main(ctx, params):
    host = params.get("host")
    community = params.get("community", "public")

    if params.get("_discover"):
        if host == None or host == "":
            return {
                "changed": False,
                "msg": "no host configured; HUS DKU not discovered",
                "data": {"discovery": []},
            }

        if not _hus_detect(ctx, host, community):
            return {
                "changed": False,
                "msg": "host is not a Hitachi HUS device",
                "data": {"discovery": []},
            }

        table = _read_dku_table(ctx, host, community)
        if len(table) == 0:
            return {
                "changed": False,
                "msg": "no DKU chassis found via SNMP",
                "data": {"discovery": []},
            }

        discovery = []
        for cid in table:
            discovery.append({
                "item": cid,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d DKU chassis" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    if host == None or host == "":
        return {
            "changed": False,
            "msg": "no host configured; cannot check HUS DKU chassis",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not _hus_detect(ctx, host, community):
        return {
            "changed": False,
            "msg": "host is not a Hitachi HUS device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    table = _read_dku_table(ctx, host, community)
    if len(table) == 0:
        return {
            "changed": False,
            "msg": "no DKU chassis found via SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    row = table.get(item)
    if row == None:
        keys = list(table.keys())
        if len(keys) == 1:
            row = table[keys[0]]
        else:
            return {
                "changed": False,
                "msg": "no such DKU chassis: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    overall_state = "OK"
    details_lines = []
    summary_parts = []
    for label, val in zip(DKU_LABELS, row[:4]):
        state_str, desc = _hus_state(val)
        details_lines.append("%s: %s (%s)" % (label, desc, state_str))
        summary_parts.append("%s: %s" % (label, desc))
        if state_str == "CRIT" and overall_state != "CRIT":
            overall_state = "CRIT"
        elif state_str == "WARN" and overall_state == "OK":
            overall_state = "WARN"
        elif state_str == "UNKNOWN" and overall_state == "OK":
            overall_state = "UNKNOWN"

    msg = ", ".join(summary_parts)
    details = "\n".join(details_lines)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall_state,
            "metrics": {},
            "details": details,
        },
    }