# ===== checkmk.cmctc_lcp_position → read-only Starlark check module =====
# Position sensor check for Rittal CMCTC LCP. SNMP-based.

SENSOR_TYPE = "position"

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
    "position": "°C",
}

_BASE_OID = ".1.3.6.1.4.1.2606.4.2"
_TREES = ["3", "4", "5", "6"]

_COL_INDEX = "5.2.1.1"
_COL_TYPEID = "5.2.1.2"
_COL_STATUS = "5.2.1.4"
_COL_READING = "5.2.1.5"
_COL_HIGH = "5.2.1.6"
_COL_LOW = "5.2.1.7"
_COL_WARN = "5.2.1.8"
_COL_DESCRIPTION = "7.2.1.2"

_CMCTC_LCP_SENSORS = {
    "32": (None, "position"),
}

STATE_MAP = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}


def _to_float(v):
    f = float(v)
    return f


def _to_int(v):
    return int(float(v))


def _snmp_walk(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        rows.append((line[:sp], line[sp + 1:].strip()))
    return rows


def _probe_cmctc(ctx, params):
    sensors = {}
    for tree in _TREES:
        base = _BASE_OID + "." + tree
        cols = {
            "index": _COL_INDEX,
            "typeid": _COL_TYPEID,
            "status": _COL_STATUS,
            "reading": _COL_READING,
            "high": _COL_HIGH,
            "low": _COL_LOW,
            "warn": _COL_WARN,
            "description": _COL_DESCRIPTION,
        }
        col_values = {}
        for key in cols:
            col_values[key] = {}
        for key, col_oid in cols.items():
            full_oid = base + "." + col_oid
            for oid_str, value in _snmp_walk(ctx, params, full_oid):
                idx = oid_str[len(full_oid) + 1:]
                col_values[key][idx] = value

        for idx, typeid in col_values["typeid"].items():
            spec = _CMCTC_LCP_SENSORS.get(typeid)
            if spec == None:
                continue
            prefix, type_key = spec
            if type_key != SENSOR_TYPE:
                continue
            if prefix:
                item = prefix + " - " + tree + "." + idx
            else:
                item = tree + "." + idx

            reading_val = col_values["reading"].get(idx, "0")
            reading = _to_float(reading_val) if reading_val != "" else 0.0
            high_val = col_values["high"].get(idx, "0")
            high = _to_float(high_val) if high_val != "" else 0.0
            low_val = col_values["low"].get(idx, "0")
            low = _to_float(low_val) if low_val != "" else 0.0
            warn_val = col_values["warn"].get(idx, "0")
            warn = _to_float(warn_val) if warn_val != "" else 0.0

            sensors[item] = {
                "status": col_values["status"].get(idx, ""),
                "reading": reading,
                "high": high,
                "low": low,
                "warn": warn,
                "description": col_values["description"].get(idx, ""),
                "type_": type_key,
            }
    return sensors


def _detect_cmctc(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc == 127:
        return False
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    if ".1.3.6.1.4.1.2606.4" in val:
        return True
    return False


def main(ctx, params):
    if not _detect_cmctc(ctx, params):
        if params.get("_discover"):
            return {"changed": False, "msg": "no Rittal CMCTC device found", "data": {"discovery": []}}
        return {"changed": False, "msg": "no Rittal CMCTC device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        sensors = _probe_cmctc(ctx, params)
        discovery = []
        for item, sensor in sensors.items():
            discovery.append({"item": item, "params": {}, "metrics": [SENSOR_TYPE]})
        return {"changed": False, "msg": "discovered %d position sensors" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    sensors = _probe_cmctc(ctx, params)
    sensor = sensors.get(item)
    if sensor == None:
        return {"changed": False, "msg": "no such position sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    st_info = _MAP_SENSOR_STATE.get(sensor["status"], (3, "unknown"))
    state_num = st_info[0]
    unit = _MAP_UNIT.get(sensor["type_"], "")

    infotext = ""
    if sensor["description"]:
        infotext = "[" + sensor["description"] + "] "
    infotext += "%d%s" % (_to_int(sensor["reading"]), unit)

    levels = params.get("levels", None)
    extra_state = 0
    extra_info = ""
    metrics = {"position": sensor["reading"]}

    if levels != None:
        warn = levels[0]
        crit = levels[1]
        metrics = {"position": {"value": sensor["reading"], "levels": {"warn": warn, "crit": crit}}}
        if sensor["reading"] >= crit:
            extra_state = 2
        elif sensor["reading"] >= warn:
            extra_state = 1
        if extra_state > 0:
            extra_info = " (warn/crit at %d/%d%s)" % (_to_int(warn), _to_int(crit), unit)
    else:
        if sensor["warn"] != 0.0:
            if sensor["reading"] >= sensor["warn"] or sensor["reading"] <= sensor["low"]:
                extra_state = 2
            extra_info = " (device crit at %d/%d%s)" % (_to_int(sensor["low"]), _to_int(sensor["warn"]), unit)

    final_state = max(state_num, extra_state)
    state_str = STATE_MAP.get(final_state, "UNKNOWN")

    msg = infotext + extra_info
    return {"changed": False, "msg": msg, "data": {"state": state_str, "metrics": metrics, "details": ""}}