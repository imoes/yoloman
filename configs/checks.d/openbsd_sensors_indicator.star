OPENBSD_MAP_STATE = {"0": "UNKNOWN", "1": "OK", "2": "WARN", "3": "CRIT"}
OPENBSD_MAP_TYPE = {"0": "temp", "1": "fan", "2": "voltage", "9": "indicator", "13": "drive", "21": "powersupply"}

COL_DESCR = "2"
COL_TYPE = "3"
COL_UNIT = "5"
COL_STATE = "6"
COL_VALUE = "7"


def _is_number(s):
    if s == "":
        return False
    if s.startswith("-"):
        s = s[1:]
    if s == "":
        return False
    parts = s.split(".")
    if len(parts) == 1:
        return s.isdigit()
    if len(parts) == 2:
        return (parts[0].isdigit() or parts[0] == "") and (parts[1].isdigit() or parts[1] == "")
    return False


def _to_number(value):
    if value == "":
        return value
    if _is_number(value):
        f = float(value)
        if f == int(f):
            return int(f)
        return f
    return value


def _dedup_name(name, used):
    count = used.get(name, 0)
    if count == 0:
        used[name] = 1
        return name
    new_name = name + "/" + str(count)
    used[name] = count + 1
    return new_name


def _fetch_sensors(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.30155.2.1.2.1"

    detect = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.30155.2.1.1.0"], mutates=False)
    if detect.rc == 127 or detect.rc != 0:
        return None

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, base + ".2"], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return {}

    table = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        suffix = "." + oid[len(base) + 1:]
        idx = suffix[len(COL_DESCR) + 1:]
        if idx.startswith("."):
            idx = idx[1:]
        table[idx] = {"descr": val}

    for col in [COL_TYPE, COL_UNIT, COL_STATE, COL_VALUE]:
        r = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, base + "." + col], mutates=False)
        if r.rc != 0:
            continue
        for line in r.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            suffix = "." + oid[len(base) + 1:]
            idx = suffix[len(col) + 1:]
            if idx.startswith("."):
                idx = idx[1:]
            if idx not in table:
                table[idx] = {}
            table[idx][col] = val

    parsed = {}
    used = {}
    for idx in sorted(table.keys()):
        e = table[idx]
        descr = e.get(COL_DESCR, "")
        sensortype = e.get(COL_TYPE, "")
        value = e.get(COL_VALUE, "")
        unit = e.get(COL_UNIT, "")
        state = e.get(COL_STATE, "")

        if sensortype not in OPENBSD_MAP_TYPE:
            continue
        if sensortype == "0" and value == "-273.15":
            continue
        if sensortype in ["1", "2"] and _is_number(value) and float(value) == 0.0:
            continue

        value_converted = _to_number(value)
        item_name = _dedup_name(descr, used)
        parsed[item_name] = {
            "state": OPENBSD_MAP_STATE.get(state, "UNKNOWN"),
            "value": value_converted,
            "unit": unit,
            "type": OPENBSD_MAP_TYPE[sensortype],
        }
    return parsed


def _state_to_rcm(state):
    return {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}.get(state, 3)


def main(ctx, params):
    if params.get("_discover"):
        section = _fetch_sensors(ctx, params)
        if section == None:
            return {"changed": False, "msg": "OpenBSD sensors not present", "data": {"discovery": []}}
        discovery = []
        for item in sorted(section.keys()):
            if section[item]["type"] == "indicator":
                discovery.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _fetch_sensors(ctx, params)
    if section == None:
        return {"changed": False, "msg": "no OpenBSD sensors found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "no such indicator: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = data["state"]
    value = data["value"]
    msg = "Status: %s" % str(value)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {}, "details": msg}}