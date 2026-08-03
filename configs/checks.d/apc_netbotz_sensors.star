# Metadata (YAML, submitted alongside this .star file):
#   name: apc_netbotz_sensors
#   fqcn: snmp.apc_netbotz_sensors
#   collection: snmp
#   short_description: Temperature / humidity / dewpoint sensors of APC NetBotz
#   description: >
#     Polls APC NetBotz environmental sensors via SNMP and reports their
#     readings with configurable thresholds (temperature, humidity, dewpoint).
#   options:
#     host:     {type: str, default: localhost, description: SNMP target host}
#     community: {type: str, default: public, description: SNMP community}
#     version: {type: str, choices: [v1, v2c], default: v2c, description: SNMP version}
#     item:    {type: str, default: "", description: sensor instance name}
#     levels:   {type: list, default: [], description: (warn, crit) upper levels}
#     levels_lower: {type: list, default: [], description: (warn, crit) lower levels}
#   writes: false
#   runtime: starlark
#   source: translated

TEMP_BASE = ".1.3.6.1.4.1.5528.100.4.1.1.1"
HUM_BASE = ".1.3.6.1.4.1.5528.100.4.1.2.1"
DWP_BASE = ".1.3.6.1.4.1.5528.100.4.1.3.1"

TEMP_BASE_50 = ".1.3.6.1.4.1.52674.500.4.1.1.1"
HUM_BASE_50 = ".1.3.6.1.4.1.52674.500.4.1.2.1"
DWP_BASE_50 = ".1.3.6.1.4.1.52674.500.4.1.3.1"

COLS = ["1", "2", "4", "7"]


def _snmp_flags(community, version):
    if version == "v1":
        return ["-v1", "-c", community]
    return ["-v2c", "-c", community]


def _walk_tree(ctx, host, community, version, base, cols):
    out = {}
    flags = _snmp_flags(community, version)
    for col in cols:
        col_oid = base + "." + col
        res = ctx.run(["snmpwalk", " ".join(flags), "-Oqn", host, col_oid],
                      mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            if not line:
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp+1:]
            idx = oid[len(col_oid)+1:]
            out.setdefault(idx, {})[col] = val
    return out


def _detect_tree(ctx, host, community, version):
    flags = _snmp_flags(community, version)
    res = ctx.run(["snmpwalk", " ".join(flags), "-Oqn", host, TEMP_BASE + ".1"],
                  mutates=False)
    if res.rc == 0 and res.stdout.strip():
        return TEMP_BASE, True
    res = ctx.run(["snmpwalk", " ".join(flags), "-Oqn", host, TEMP_BASE_50 + ".1"],
                  mutates=False)
    if res.rc == 0 and res.stdout.strip():
        return TEMP_BASE_50, False
    return None, None


def _parse_reading(s, div):
    if not s or s == "":
        return None
    cleaned = s.replace("-", "").replace(".", "")
    valid = True
    for ch in cleaned:
        if not (ch >= "0" and ch <= "9"):
            valid = False
            break
    if not valid:
        return None
    return float(s) / div


def _collect_sensors(ctx, host, community, version):
    base, is_v2 = _detect_tree(ctx, host, community, version)
    if base == None:
        return None
    hum_b = HUM_BASE if base == TEMP_BASE else HUM_BASE_50
    dwp_b = DWP_BASE if base == TEMP_BASE else DWP_BASE_50
    div = 10.0 if is_v2 else 1.0
    temp = _walk_tree(ctx, host, community, version, base, COLS)
    hum = _walk_tree(ctx, host, community, version, hum_b, COLS)
    dwp = _walk_tree(ctx, host, community, version, dwp_b, COLS)
    section = {"temp": {}, "humidity": {}, "dewpoint": {}}
    for st, tree in (("temp", temp), ("humidity", hum), ("dewpoint", dwp)):
        for idx, cols_d in tree.items():
            plugged = cols_d.get("2", "1")
            if plugged == "" or plugged == "0":
                continue
            reading = _parse_reading(cols_d.get("4", ""), div)
            if reading == None:
                continue
            label = cols_d.get("7", "")
            item_name = cols_d.get("1", idx)
            section[st][item_name] = {"reading": reading, "label": label}
    return section


def _threshold_state(value, levels, levels_lower):
    if len(levels) >= 2:
        w, c = levels[0], levels[1]
        if value >= c:
            return "CRIT"
        if value >= w:
            return "WARN"
    if len(levels_lower) >= 2:
        w, c = levels_lower[0], levels_lower[1]
        if value <= c:
            return "CRIT"
        if value <= w:
            return "WARN"
    return "OK"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "v2c")
    item = params.get("item", "")
    levels = params.get("levels", [])
    levels_lower = params.get("levels_lower", [])

    if params.get("_discover"):
        section = _collect_sensors(ctx, host, community, version)
        if section == None:
            return {"changed": False, "msg": "APC NetBotz not found via SNMP",
                    "data": {"discovery": []}}
        out = []
        for st in ("temp", "humidity", "dewpoint"):
            for name, d in section[st].items():
                metric = "temperature" if st == "temp" else (
                    "humidity" if st == "humidity" else "dewpoint")
                out.append({
                    "item": "%s %s" % (st, name),
                    "params": {"host": host, "community": community,
                               "version": version, "levels": [],
                               "levels_lower": []},
                    "metrics": [metric],
                    "service_labels": {"sensor_type": st,
                                       "sensor_label": d["label"]},
                })
        return {"changed": False,
                "msg": "discovered %d APC NetBotz sensors" % len(out),
                "data": {"discovery": out}}

    section = _collect_sensors(ctx, host, community, version)
    if section == None:
        return {"changed": False, "msg": "no APC NetBotz found via SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = item.split(" ", 1)
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    st, name = parts[0], parts[1]
    if st not in section:
        return {"changed": False, "msg": "unknown sensor type: %s" % st,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sensors = section[st]
    if name not in sensors:
        return {"changed": False, "msg": "sensor not found: %s %s" % (st, name),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    d = sensors[name]
    reading = d["reading"]
    label = d["label"]
    st_name = "temperature" if st == "temp" else (
        "humidity" if st == "humidity" else "dewpoint")
    metric = {st_name: reading}
    state = _threshold_state(reading, levels, levels_lower)
    msg = "[%s] %s: %s" % (label, st_name, str(reading))
    details = st_name.capitalize() + " " + str(reading) + " " + state
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metric, "details": details}}