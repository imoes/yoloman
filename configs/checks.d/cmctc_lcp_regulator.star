# Regulator %s  —  Rittal LCP regulator check (Starlark, read-only SNMP)

# Sensor typeid -> (name_prefix or None, type)
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

# SNMP trees walked: cmcTcUnit{1..4}OutputTable
_TREES = ["3", "4", "5", "6"]

# Column OIDs relative to each tree base (.1.3.6.1.4.1.2606.4.2.<tree>)
_COL_INDEX = "5.2.1.1"
_COL_TYPEID = "5.2.1.2"
_COL_STATUS = "5.2.1.4"
_COL_READING = "5.2.1.5"
_COL_HIGH = "5.2.1.6"
_COL_LOW = "5.2.1.7"
_COL_WARN = "5.2.1.8"
_COL_DESC = "7.2.1.2"

# sensor status -> (state, text)
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
    "temp": "\u00b0C",
    "blower": " RPM",
    "blowergrade": "",
    "humidity": "%",
    "flow": " l/min",
    "regulator": "%",
    "user": "",
}

SENSORTYPE = "regulator"


def _snmp_oid(base, col, index):
    return ".".join([base, col, index])


def _walk_unit(ctx, host, community, tree, col):
    base = ".1.3.6.1.4.1.2606.4.2." + tree
    column_oid = ".".join([base, col])
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    rows = []
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        if not oid.startswith(column_oid + "."):
            continue
        index = oid[len(column_oid) + 1:]
        rows.append((index, value))
    return rows


def _parse_sensor(ctx, host, community, tree, index):
    base = ".1.3.6.1.4.1.2606.4.2." + tree
    typeid = _snmpget_str(ctx, host, community, base, _COL_TYPEID, index)
    if typeid == None:
        return None
    spec = _CMCTC_LCP_SENSORS.get(typeid)
    if spec == None:
        return None
    return {
        "type_": spec[1],
        "status": _snmpget_str(ctx, host, community, base, _COL_STATUS, index),
        "reading": _snmpget_float(ctx, host, community, base, _COL_READING, index),
        "high": _snmpget_float(ctx, host, community, base, _COL_HIGH, index),
        "low": _snmpget_float(ctx, host, community, base, _COL_LOW, index),
        "warn": _snmpget_float(ctx, host, community, base, _COL_WARN, index),
        "description": _snmpget_str(ctx, host, community, base, _COL_DESC, index),
        "tree": tree,
        "index": index,
    }


def _snmpget_str(ctx, host, community, base, col, index):
    oid = _snmp_oid(base, col, index)
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmpget_float(ctx, host, community, base, col, index):
    val = _snmpget_str(ctx, host, community, base, col, index)
    if val == None or val == "":
        return 0.0
    parsed = _to_float(val)
    if parsed == None:
        return 0.0
    return parsed


def _to_float(s):
    neg = False
    work = s
    if work.startswith("-"):
        neg = True
        work = work[1:]
    elif work.startswith("+"):
        work = work[1:]
    if work == "" or work == ".":
        return None
    parts = work.split(".")
    if len(parts) > 2:
        return None
    for p in parts:
        if p == "":
            continue
        if not p.isdigit():
            return None
    if not work.isdigit() and "." not in work:
        return None
    f = float(s)
    if neg:
        f = -f
    return f


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- discovery ---
    if params.get("_discover"):
        discovery = []
        for tree in _TREES:
            rows = _walk_unit(ctx, host, community, tree, _COL_TYPEID)
            for index, typeid in rows:
                spec = _CMCTC_LCP_SENSORS.get(typeid)
                if spec == None:
                    continue
                if spec[1] != SENSORTYPE:
                    continue
                prefix = spec[0]
                if prefix != None:
                    item = prefix + " - " + tree + "." + index
                else:
                    item = tree + "." + index
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": [SENSORTYPE],
                })
        return {
            "changed": False,
            "msg": "discovered %d regulator sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- check ---
    item = params.get("item", "")
    last_dot = item.rfind(".")
    if last_dot == -1:
        return {
            "changed": False,
            "msg": "no such regulator sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    index = item[last_dot + 1:]
    rest = item[:last_dot]
    dash = rest.rfind(" - ")
    if dash != -1:
        tree = rest[dash + 3:]
    else:
        tree = rest
    valid_tree = False
    for t in _TREES:
        if t == tree:
            valid_tree = True
            break
    if not valid_tree:
        return {
            "changed": False,
            "msg": "no such regulator sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensor = _parse_sensor(ctx, host, community, tree, index)
    if sensor == None:
        return {
            "changed": False,
            "msg": "no such regulator sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    unit = _MAP_UNIT.get(sensor["type_"], "")
    infotext = ""
    if sensor["description"] != None and sensor["description"] != "":
        infotext += "[%s] " % sensor["description"]

    state_pair = _MAP_SENSOR_STATE.get(sensor["status"], (3, "unknown"))
    state_num = state_pair[0]
    extra_info = state_pair[1]

    extra_state = 0
    warn = params.get("warn")
    crit = params.get("crit")
    if warn != None and crit != None:
        reading = sensor["reading"]
        if reading >= crit:
            extra_state = 2
        elif reading >= warn:
            extra_state = 1
        if extra_state != 0:
            extra_info = extra_info + " (warn/crit at %d/%d%s)" % (int(warn), int(crit), unit)
    else:
        low = sensor["low"]
        high = sensor["high"]
        warn_v = sensor["warn"]
        if low != 0.0 or high != 0.0 or warn_v != 0.0:
            if (low != 0.0 and high != 0.0) and low < high:
                reading = sensor["reading"]
                if reading >= high or reading <= low:
                    extra_state = 2
                    extra_info = extra_info + " (device lower/upper crit at %f/%f%s)" % (low, high, unit)

    metrics = {SENSORTYPE: sensor["reading"]}
    msg = infotext + "%d%s" % (int(sensor["reading"]), unit)
    if extra_info != "" and extra_info != state_pair[1]:
        msg = msg + " " + extra_info

    final_state = state_num if state_num != 0 else extra_state
    state_str = "OK"
    if final_state == 1:
        state_str = "WARN"
    elif final_state == 2:
        state_str = "CRIT"
    elif final_state == 3:
        state_str = "UNKNOWN"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_str,
            "metrics": metrics,
            "details": extra_info,
        },
    }