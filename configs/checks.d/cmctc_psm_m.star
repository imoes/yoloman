def _walk_table(host, community, version, column_oid, ctx):
    res = ctx.run(
        ["snmpwalk", "-v", version, "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    rows = {}
    if res.rc == 0 and res.stdout != "":
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            if not oid.startswith(column_oid + "."):
                continue
            idx = oid[len(column_oid) + 1:]
            if idx == "":
                continue
            rows[idx] = val
    return rows


def _is_float(s):
    if s == "":
        return False
    body = s
    if body.startswith("-") or body.startswith("+"):
        body = body[1:]
    if body == "":
        return False
    parts = body.split(".")
    if len(parts) == 1:
        return parts[0].isdigit()
    if len(parts) == 2:
        if parts[0] == "" and parts[1] == "":
            return False
        left_ok = parts[0].isdigit() if parts[0] != "" else True
        return left_ok and parts[1].isdigit()
    return False


def _sort_key(s):
    parts = s.split(".")
    int_parts = []
    for p in parts:
        ip = int(p) if p.isdigit() else 0
        int_parts.append(ip)
    return int_parts


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    if params.get("_discover"):
        sys_oid = ".1.3.6.1.2.1.1.2.0"
        res = ctx.run(
            ["snmpget", "-v", version, "-c", community, "-Ov", host, sys_oid],
            mutates=False,
        )
        detected = res.rc == 0 and res.stdout != "" and ".1.3.6.1.4.1.2606.4" in res.stdout
        if not detected:
            return {"changed": False, "msg": "not a Rittal CMCTC device", "data": {"discovery": []}}

        discovery = []
        for idx in ["3", "4", "5", "6"]:
            base = ".1.3.6.1.4.1.2606.4.2." + idx + ".5.2.1"
            index_col = _walk_table(host, community, version, base + ".1", ctx)
            if not index_col:
                continue
            type_col = _walk_table(host, community, version, base + ".2", ctx)
            status_col = _walk_table(host, community, version, base + ".4", ctx)
            reading_col = _walk_table(host, community, version, base + ".5", ctx)
            descr_col = _walk_table(host, community, version, base + ".3", ctx)

            for sensor_idx in sorted(index_col.keys(), key=_sort_key):
                desc = descr_col.get(sensor_idx, "")
                item = (desc + " " + idx + "." + sensor_idx) if desc != "" else idx + "." + sensor_idx
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": [item + "_reading"],
                })
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = item.split(" ")
    if len(parts) == 2:
        desc = parts[0]
        idx_dot = parts[1].find(".")
        if idx_dot == -1:
            return {"changed": False, "msg": "invalid item format", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        unit_idx = parts[1][:idx_dot]
        sensor_idx = parts[1][idx_dot + 1:]
    else:
        desc = ""
        dot = item.find(".")
        if dot == -1:
            return {"changed": False, "msg": "invalid item format", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        unit_idx = item[:dot]
        sensor_idx = item[dot + 1:]

    base = ".1.3.6.1.4.1.2606.4.2." + unit_idx + ".5.2.1"
    type_res = ctx.run(
        ["snmpget", "-v", version, "-c", community, "-Oqv", host, base + ".2." + sensor_idx],
        mutates=False,
    )
    status_res = ctx.run(
        ["snmpget", "-v", version, "-c", community, "-Oqv", host, base + ".4." + sensor_idx],
        mutates=False,
    )
    reading_res = ctx.run(
        ["snmpget", "-v", version, "-c", community, "-Oqv", host, base + ".5." + sensor_idx],
        mutates=False,
    )
    descr_res = ctx.run(
        ["snmpget", "-v", version, "-c", community, "-Oqv", host, base + ".3." + sensor_idx],
        mutates=False,
    )

    if type_res.rc != 0 or status_res.rc != 0 or reading_res.rc != 0 or descr_res.rc != 0:
        return {"changed": False, "msg": "sensor not reachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_type = type_res.stdout.strip()
    status_str = status_res.stdout.strip()
    reading_str = reading_res.stdout.strip()
    descr_str = descr_res.stdout.strip()

    unit_map = {
        "72": "kW", "73": "kW", "74": "hz", "75": "V",
        "77": "A", "79": "kW", "80": "kW",
    }
    unit = unit_map.get(sensor_type, "unknown")

    status = 0
    if status_str.isdigit():
        status = int(status_str)

    reading = 0.0
    if _is_float(reading_str):
        reading = float(reading_str) / 10.0

    status_text = {
        "1": "notAvail", "2": "lost", "3": "changed", "4": "ok",
        "5": "off", "6": "on", "7": "warning", "8": "tooLow", "9": "tooHigh",
    }.get(str(status), "UNKNOWN")

    state = "CRIT"
    if status == 4:
        state = "OK"
    elif status in (7, 8, 9):
        state = "WARN"
    elif status in (1, 2, 3):
        state = "CRIT"

    if descr_str == "" and desc != "":
        descr_str = desc

    msg = descr_str + " at " + str(reading) + unit + " (" + status_text + ")"
    metric_name = (desc + " " + unit_idx + "." + sensor_idx) if desc != "" else unit_idx + "." + sensor_idx
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {metric_name + "_reading": reading},
            "details": "",
        },
    }