TREES = ["3", "4", "5", "6"]
BLOWERGRADE_TYPEID = "61"

SENSOR_STATE_MAP = {
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

STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}


def _is_numeric(s):
    if not s:
        return False
    t = s.strip()
    if t.startswith("-"):
        t = t[1:]
    if not t:
        return False
    if t.count(".") > 1:
        return False
    if "." in t:
        parts = t.split(".")
        return parts[0].isdigit() and parts[1].isdigit()
    return t.isdigit()


def _to_float(s):
    return float(s.strip()) if _is_numeric(s) else 0.0


def _parse_snmpwalk(output):
    result = {}
    for line in output.splitlines():
        if " = " not in line:
            continue
        parts = line.split(" = ", 1)
        oid = parts[0].strip()
        val_part = parts[1].strip()
        if ": " in val_part:
            val = val_part.split(": ", 1)[1]
        else:
            val = val_part
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        result[oid] = val
    return result


def _get_sensors(ctx, host, community, tree):
    base = ".1.3.6.1.4.1.2606.4.2." + tree
    res5 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, base + ".5.2.1"],
        mutates=False,
        ok_codes=[0, 1],
    )
    res7 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, base + ".7.2.1.2"],
        mutates=False,
        ok_codes=[0, 1],
    )

    table5 = _parse_snmpwalk(res5.stdout)
    table7 = _parse_snmpwalk(res7.stdout)

    prefix5 = base + ".5.2.1."
    rows = {}
    for oid in table5.keys():
        if not oid.startswith(prefix5):
            continue
        rest = oid[len(prefix5):]
        dot_pos = rest.find(".")
        if dot_pos < 0:
            continue
        col = rest[:dot_pos]
        row = rest[dot_pos + 1:]
        if row not in rows:
            rows[row] = {}
        rows[row][col] = table5[oid]

    prefix7 = base + ".7.2.1.2."
    descs = {}
    for oid in table7.keys():
        if not oid.startswith(prefix7):
            continue
        descs[oid[len(prefix7):]] = table7[oid]

    row_keys = sorted([(int(r) if r.isdigit() else 0, r) for r in rows.keys()])
    sensors = []
    for _, row in row_keys:
        cols = rows[row]
        sensors.append({
            "index": cols.get("1", row),
            "typeid": cols.get("2", ""),
            "status": cols.get("4", "1"),
            "reading": _to_float(cols.get("5", "0")),
            "high": _to_float(cols.get("6", "0")),
            "low": _to_float(cols.get("7", "0")),
            "warn_dev": _to_float(cols.get("8", "0")),
            "description": descs.get(row, ""),
        })
    return sensors


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        discovered = []
        for tree in TREES:
            sensors = _get_sensors(ctx, host, community, tree)
            for s in sensors:
                if s["typeid"] == BLOWERGRADE_TYPEID:
                    item = tree + "." + s["index"]
                    discovered.append({
                        "item": item,
                        "params": {},
                        "metrics": ["blowergrade"],
                    })
        return {
            "changed": False,
            "msg": "discovered %d blowergrade sensor(s)" % len(discovered),
            "data": {"discovery": discovered},
        }

    item = params.get("item", "")
    dot_pos = item.find(".")
    if dot_pos < 0:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    tree = item[:dot_pos]
    index = item[dot_pos + 1:]

    if tree not in TREES:
        return {
            "changed": False,
            "msg": "unknown SNMP tree in item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensors = _get_sensors(ctx, host, community, tree)
    sensor = None
    for s in sensors:
        if s["typeid"] == BLOWERGRADE_TYPEID and s["index"] == index:
            sensor = s
            break

    if sensor == None:
        return {
            "changed": False,
            "msg": "blowergrade sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status_str = sensor["status"]
    state_info = SENSOR_STATE_MAP.get(status_str, (3, "unknown"))
    state_int = state_info[0]

    reading = sensor["reading"]
    description = sensor["description"]

    infotext = ("[%s] " % description) if description else ""
    summary = "%s%d" % (infotext, int(reading))

    warn_param = params.get("warn", None)
    crit_param = params.get("crit", None)

    extra_state = 0
    extra_info = ""

    if warn_param != None and crit_param != None:
        if reading >= crit_param:
            extra_state = 2
        elif reading >= warn_param:
            extra_state = 1
        if extra_state:
            extra_info = " (warn/crit at %d/%d)" % (int(warn_param), int(crit_param))
    else:
        high = sensor["high"]
        low = sensor["low"]
        warn_dev = sensor["warn_dev"]
        not_all_zero = not (low == 0.0 and warn_dev == 0.0 and high == 0.0)
        has_levels = not_all_zero and (low < high)
        if has_levels:
            if reading >= high or reading <= low:
                extra_state = 2
                extra_info = " (device lower/upper crit at %d/%d)" % (int(low), int(high))

    final_state_int = state_int if state_int > extra_state else extra_state
    final_state = STATE_NAMES.get(final_state_int, "UNKNOWN")

    return {
        "changed": False,
        "msg": summary + extra_info,
        "data": {
            "state": final_state,
            "metrics": {"blowergrade": reading},
            "details": "",
        },
    }