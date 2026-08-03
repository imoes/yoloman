# Rittal LCP waterflow sensors — translated from Checkmk cmctc_lcp_flow.
# This is an SNMP-table per-item check. It discovers flow sensors (typeid "23"),
# reports the waterflow reading with status levels.

_TREES = ["3", "4", "5", "6"]

_COLUMNS = [
    "5.2.1.1",  # index
    "5.2.1.2",  # typeid
    "5.2.1.4",  # status
    "5.2.1.5",  # reading
    "5.2.1.6",  # high
    "5.2.1.7",  # low
    "5.2.1.8",  # warn
    "7.2.1.2",  # description
]

_BASE = ".1.3.6.1.4.1.2606.4.2"

# typeid -> (prefix, sensortype)
_CMCTC_LCP_SENSORS = {
    "4": (None, "access"),
    "12": (None, "humidity"),
    "13": ("normally open", "user"),
    "14": ("normally closed", "user"),
    "23": (None, "flow"),
    "30": (None, "current"),
    "31": (None, "status"),
    "32": (None, "position"),
    "40": ("1", "blower"),
    "41": ("2", "blower"),
    "42": ("3", "blower"),
    "43": ("4", "blower"),
    "44": ("5", "blower"),
    "45": ("6", "blower"),
    "46": ("7", "blower"),
    "47": ("8", "blower"),
    "48": ("Server in 1", "temp"),
    "49": ("Server out 1", "temp"),
    "50": ("Server in 2", "temp"),
    "51": ("Server out 2", "temp"),
    "52": ("Server in 3", "temp"),
    "53": ("Server out 3", "temp"),
    "54": ("Server in 4", "temp"),
    "55": ("Server out 4", "temp"),
    "56": ("Overview Server in", "temp"),
    "57": ("Overview Server out", "temp"),
    "58": ("Water in", "temp"),
    "59": ("Water out", "temp"),
    "60": (None, "flow"),
    "61": (None, "blowergrade"),
    "62": (None, "regulator"),
}

# status code -> (state_level, text)
_MAP_SENSOR_STATE = {
    "1": (3, "not available"),
    "2": (2, "lost"),
    "3": (1, "changed"),
    "4": (0, "ok"),
    "5": (2, "off"),
    "6": (0, "on"),
    "7": (1, "warning"),
    "8": (2, "too low"),
    "9": (2, "too high"),
    "10": (2, "error"),
}

_MAP_UNIT = {
    "access": "",
    "current": " A",
    "status": "",
    "position": "",
    "temp": " \u00b0C",
    "blower": " RPM",
    "blowergrade": "",
    "humidity": "%",
    "flow": " l/min",
    "regulator": "%",
    "user": "",
}


def _to_float(v):
    if v == None:
        return None
    if type(v) == "string":
        if v == "":
            return None
        return float(v)
    return float(v)


def _walk_column(ctx, host, community, col_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        rows.append((oid, val))
    return rows


def _get_scalar(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_get_table(ctx, host, community, tree_idx):
    base = _BASE + "." + tree_idx
    # Walk each column OID to collect the index->value maps.
    col_oids = {}
    for c in _COLUMNS:
        col_oids[c] = base + "." + c
    # Build a map: index -> {col_label: value}
    data = {}  # index -> dict
    col_labels = _COLUMNS
    # We need to walk each column and split off the index suffix.
    # column_oid is base + "." + col_label, e.g. base.5.2.1.1
    idx_values = {}  # index -> list aligned with col_labels
    for c in col_labels:
        full = base + "." + c
        rows = _walk_column(ctx, host, community, full)
        for (oid, val) in rows:
            suffix = oid[len(full) + 1:] if oid.startswith(full + ".") else None
            if suffix == None:
                continue
            if suffix not in data:
                data[suffix] = {}
            data[suffix][c] = val
    return data


def _parse_block(ctx, host, community, tree_idx):
    data = _snmp_get_table(ctx, host, community, tree_idx)
    out = []
    for index, cols in data.items():
        # columns: 5.2.1.1=index, 5.2.1.2=typeid, 5.2.1.4=status, 5.2.1.5=reading,
        # 5.2.1.6=high, 5.2.1.7=low, 5.2.1.8=warn, 7.2.1.2=description
        typeid = cols.get("5.2.1.2")
        spec = _CMCTC_LCP_SENSORS.get(typeid)
        if spec == None:
            continue
        out.append({
            "tree": tree_idx,
            "index": index,
            "typeid": typeid,
            "status": cols.get("5.2.1.4"),
            "reading": cols.get("5.2.1.5"),
            "high": cols.get("5.2.1.6"),
            "low": cols.get("5.2.1.7"),
            "warn": cols.get("5.2.1.8"),
            "description": cols.get("7.2.1.2"),
            "prefix": spec[0],
            "type_": spec[1],
        })
    return out


def _all_sensors(ctx, host, community):
    sensors = []
    for tree_idx in _TREES:
        sensors.extend(_parse_block(ctx, host, community, tree_idx))
    return sensors


def _item_name(prefix, tree, index):
    if prefix != None:
        return prefix + " - " + tree + "." + index
    return tree + "." + index


def _flow_sensors(ctx, host, community):
    out = []
    for s in _all_sensors(ctx, host, community):
        if s["type_"] == "flow":
            out.append(s)
    return out


def _state_from_levels(reading, warn, crit, lower):
    if crit != None and reading >= crit:
        return "CRIT"
    if lower and lower != None and reading <= lower:
        return "CRIT"
    if warn != None and reading >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sensortype = "flow"

    # Verify the device is a Rittal CMCTC via sysObjectID.
    sysid = _get_scalar(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sysid == None or not sysid.startswith(".1.3.6.1.4.1.2606.4"):
        if params.get("_discover"):
            return {"changed": False, "msg": "not a Rittal CMCTC", "data": {"discovery": []}}
        return {"changed": False, "msg": "not a Rittal CMCTC",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        sensors = _flow_sensors(ctx, host, community)
        discovery = []
        for s in sensors:
            item = _item_name(s["prefix"], s["tree"], s["index"])
            discovery.append({
                "item": item,
                "params": {"warn": 80, "crit": 90},
                "metrics": [sensortype],
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    sensors = _flow_sensors(ctx, host, community)
    target = None
    for s in sensors:
        if _item_name(s["prefix"], s["tree"], s["index"]) == item:
            target = s
            break

    if target == None:
        return {"changed": False,
                "msg": "no such waterflow sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading = _to_float(target["reading"])
    high = _to_float(target["high"])
    low = _to_float(target["low"])
    warn = _to_float(target["warn"])
    if reading == None:
        return {"changed": False,
                "msg": "no reading for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    unit = _MAP_UNIT.get(sensortype, "")
    desc = target["description"]
    infotext = ""
    if desc != None and desc != "":
        infotext += "[" + desc + "] "

    st = target["status"]
    smap = _MAP_SENSOR_STATE.get(st)
    if smap != None:
        state_level = smap[0]
        extra_info = smap[1]
    else:
        state_level = 3
        extra_info = "unknown status " + str(st)

    summary = infotext + str(int(reading)) + unit

    metrics = {"flow": reading}
    if params:
        warn_p = params.get("warn")
        crit_p = params.get("crit")
        if warn_p != None:
            warn = float(warn_p)
        if crit_p != None:
            crit = float(crit_p)
        if crit != None:
            metrics["flow_levels"] = crit
    else:
        if warn != None and high != None and low != None:
            if (low != 0.0 or warn != 0.0 or high != 0.0) and low < high:
                warn = warn
                crit = high

    final_state = "OK"
    if state_level >= 2:
        final_state = "CRIT"
    elif state_level == 1:
        final_state = "WARN"

    return {"changed": False,
            "msg": summary,
            "data": {"state": final_state, "metrics": metrics, "details": extra_info}}