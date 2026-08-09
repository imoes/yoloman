def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-Oqn", "-On", "-IR",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.37954.1.2",
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no kentix device found",
                    "data": {"discovery": [], "host_labels": {}}}

        sensors = {}
        for line in res.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) != 2:
                continue
            oid, value = sp
            rest = oid[len(".1.3.6.1.4.1.37954.1.2."):]
            parts = rest.split(".")
            if len(parts) < 2:
                continue
            sensor_idx = parts[0]
            col = parts[1]
            if not sensor_idx or not col:
                continue
            if col == "2":
                sensors.setdefault(sensor_idx, {})["name"] = value
        if not sensors:
            return {"changed": False, "msg": "no kentix sensors found",
                    "data": {"discovery": [], "host_labels": {}}}

        out = []
        for idx in sensors:
            name = sensors[idx].get("name", idx)
            out.append({"item": name, "params": {}, "metrics": ["leakage"]})
        return {"changed": False,
                "msg": "discovered %d leakage sensors" % len(out),
                "data": {"discovery": out,
                         "host_labels": {"cmk/snmp": "yes"}}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no leakage sensor item given",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base = ".1.3.6.1.4.1.37954.1.2.7"
    name_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.37954.1.2.7.1",
    ], mutates=False)
    if name_res.rc != 0 or not name_res.stdout.strip():
        return {"changed": False, "msg": "no kentix sensors found",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "kentix device not reachable"}}

    found_idx = None
    for line in name_res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) != 2:
            continue
        oid, value = sp
        rest = oid[len(base + ".1."):]
        parts = rest.split(".")
        sensor_idx = parts[0] if parts else ""
        if value == item or sensor_idx == item:
            found_idx = sensor_idx
            break
    if found_idx == None:
        return {"changed": False, "msg": "no such leakage sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    leak_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", "-On",
        params.get("host", "localhost"),
        base + ".7." + found_idx,
    ], mutates=False)
    if leak_res.rc != 0 or not leak_res.stdout.strip():
        return {"changed": False, "msg": "could not read leakage value",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "no leakage data returned"}}

    raw = leak_res.stdout.strip()
    digits = raw.lstrip("-")
    if not digits.isdigit():
        return {"changed": False, "msg": "invalid leakage value: " + raw,
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": ""}}
    leakage = int(raw)
    if leakage > 0:
        state = "CRIT"
        summary = "Alarm or disconnected"
    else:
        state = "OK"
        summary = "Connected"
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"leakage": leakage},
                     "details": summary}}