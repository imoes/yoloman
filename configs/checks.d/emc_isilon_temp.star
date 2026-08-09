def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    is_cpu = params.get("is_cpu", False)
    levels = params.get("levels", (28.0, 33.0))
    if is_cpu:
        levels = params.get("levels", (75.0, 85.0))
    warn = levels[0]
    crit = levels[1]

    if params.get("_discover"):
        sys_descr = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.1.0")
        if not _is_isilon(sys_descr):
            return {"changed": False, "msg": "not an Isilon device",
                    "data": {"discovery": []}}
        section = _fetch_temp_section(ctx, host, community)
        discovery = []
        for sensor_name, _value in section:
            item_name = _isilon_temp_item_name(sensor_name)
            if is_cpu == item_name.startswith("CPU"):
                discovery.append({"item": item_name, "params": {"levels": levels},
                                  "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _fetch_temp_section(ctx, host, community)
    value = None
    for sensor_name, v in section:
        if item == _isilon_temp_item_name(sensor_name):
            value = v
            break
    if value == None:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temp = _to_float(value)
    if temp == None:
        return {"changed": False, "msg": "invalid temperature value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    return {"changed": False,
            "msg": "%s temperature: %s C" % (item, _fmt(temp)),
            "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}


def _isilon_temp_item_name(sensor_name):
    if "CPU Throttle" in sensor_name:
        inner = sensor_name.split("(", 1)
        if len(inner) == 2:
            rest = inner[1].split(")", 1)[0]
            return rest
    if len(sensor_name) >= 6 and sensor_name[:5] == "Temp ":
        return sensor_name[5:]
    return sensor_name


def _snmp_get(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                  mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
                  mutates=False)
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            lines.append((parts[0], parts[1]))
    return lines


def _fetch_temp_section(ctx, host, community):
    base = ".1.3.6.1.4.1.12124.2.54.1"
    cols = _snmp_walk(ctx, host, community, base + ".3")
    val_map = {}
    for oid, val in _snmp_walk(ctx, host, community, base + ".4"):
        idx = oid[len(base) + 3:]
        val_map[idx] = val
    section = []
    for oid, name in cols:
        idx = oid[len(base) + 3:]
        if idx in val_map:
            section.append((name.strip('"'), val_map[idx]))
    return section


def _is_isilon(sys_descr):
    return "isilon" in sys_descr.lower()


def _to_float(value):
    s = value.strip().strip('"')
    if s == "":
        return None
    try_int = s
    if try_int[0] in "+-":
        rest = try_int[1:]
    else:
        rest = try_int
    if rest == "" or not rest.replace(".", "").isdigit():
        return None
    if rest.count(".") > 1:
        return None
    return float(s)


def _fmt(temp):
    return "%f" % temp