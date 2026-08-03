_STATE_MAP = {
    "1": ("OK", "charging"),
    "2": ("WARN", "discharging"),
    "3": ("CRIT", "i2c errors detected"),
    "4": ("OK", "learn cycle active"),
    "5": ("CRIT", "learn cycle failed"),
    "6": ("OK", "learn cycle requested"),
    "7": ("CRIT", "learn cycle timeout"),
    "8": ("CRIT", "pack missing"),
    "9": ("CRIT", "temperature high"),
    "10": ("CRIT", "voltage low"),
    "11": ("WARN", "periodic learn required"),
    "12": ("WARN", "remaining capacity low"),
    "13": ("CRIT", "replace pack"),
    "14": ("OK", "normal"),
    "15": ("WARN", "undefined"),
}

_TYPE_MAP = {
    "1": "no battery present",
    "2": "ibbu",
    "3": "bbu",
    "4": "zcrLegacyBBU",
    "5": "itbbu3",
    "6": "ibbu08",
    "7": "unknown",
}

_DATAPOWER_SYSOIDS = [
    ".1.3.6.1.4.1.14685.1.8",
    ".1.3.6.1.4.1.14685.1.7",
    ".1.3.6.1.4.1.14685.1.3",
]

_BASE = ".1.3.6.1.4.1.14685.3.1.258.1"


def _walk_table(ctx, params, column_oid):
    """Walk a single SNMP table column with -Oqn; return list of (index, value)."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"), column_oid],
        mutates=False,
    )
    rows = []
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        idx = oid[len(column_oid) + 1:]
        if idx == "":
            continue
        rows.append((idx, line[sp + 1:].strip()))
    return rows


def _is_datapower(ctx, params):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val in _DATAPOWER_SYSOIDS


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _is_datapower(ctx, params):
            return {"changed": False, "msg": "not a Datapower device",
                    "data": {"discovery": []}}
        # Column 1 = controller id; index is consistent across all columns.
        controllers = _walk_table(ctx, params, _BASE + ".1")
        out = []
        for idx, oid in controllers:
            out.append({"item": oid, "params": {},
                        "metrics": []})
        return {"changed": False,
                "msg": "discovered %d raid batteries" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if not _is_datapower(ctx, params):
        return {"changed": False,
                "msg": "not a Datapower device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Pull all columns keyed by table index.
    cols = {}
    for col_n, col_idx in [("1", "controller"), ("2", "type"), ("3", "serial"),
                           ("4", "name"), ("5", "status")]:
        col_oid = _BASE + "." + col_n
        rows = _walk_table(ctx, params, col_oid)
        col_map = {}
        for idx, val in rows:
            col_map[idx] = val
        cols[col_idx] = col_map

    # Find the controller whose id matches the requested item.
    controller_col = cols.get("controller", {})
    match_idx = None
    for idx, oid in controller_col.items():
        if oid == item:
            match_idx = idx
            break
    if match_idx == None:
        return {"changed": False,
                "msg": "no such raid battery controller: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_val = cols.get("status", {}).get(match_idx, "0")
    parsed = _STATE_MAP.get(status_val)
    if parsed == None:
        state = "UNKNOWN"
        state_txt = "unknown status code: %s" % status_val
    else:
        state, state_txt = parsed

    bat_type = cols.get("type", {}).get(match_idx, "0")
    type_txt = _TYPE_MAP.get(bat_type, "unknown type code: %s" % bat_type)
    serial = cols.get("serial", {}).get(match_idx, "")
    name = cols.get("name", {}).get(match_idx, "")

    infotext = "Status: %s, Name: %s, Type: %s, Serial: %s" % (
        state_txt, name, type_txt, serial)

    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": {}, "details": ""}}