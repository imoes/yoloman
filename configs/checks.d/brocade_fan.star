def check_fan(value, params):
    warn = None
    crit = None
    lower = params.get("lower", None) if type(params) == "dict" else None
    if type(params) == "dict" and lower != None and type(lower) == "list" and len(lower) == 2:
        warn = lower[1]
        crit = lower[0]
    if warn == None or crit == None:
        warn = params.get("warn", 3000) if type(params) == "dict" else 3000
        crit = params.get("crit", 2800) if type(params) == "dict" else 2800
    if value >= crit:
        return ["CRIT", {"rpm": value}, "FAN %d RPM below critical threshold %d" % (value, crit)]
    if value >= warn:
        return ["WARN", {"rpm": value}, "FAN %d RPM below warning threshold %d" % (value, warn)]
    return ["OK", {"rpm": value}, "FAN %d RPM above warning threshold %d" % (value, warn)]


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-OvQ", params.get("host", "localhost"),
                       ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "sysObjectID not reachable",
                    "data": {"discovery": []}}
        sysoid = res.stdout.strip()
        brocade_prefixes = [".1.3.6.1.4.1.1588.2.1.1", ".1.3.6.1.2.4.1.1588.2.1.1",
                            ".1.3.6.1.4.1.1588.2.2.1", ".1.3.6.1.4.1.1588.3.3.1",
                            ".1.3.6.1.4.1.1916.2.306"]
        is_brocade = False
        for p in brocade_prefixes:
            if sysoid.startswith(p):
                is_brocade = True
                break
        if not is_brocade:
            return {"changed": False, "msg": "not a Brocade device",
                    "data": {"discovery": []}}

        col3 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"),
                        ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1.3"], mutates=False)
        col4 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"),
                        ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1.4"], mutates=False)
        col5 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"),
                        ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1.5"], mutates=False)

        base1 = ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1"
        col_map = {base1 + ".3": col3, base1 + ".4": col4, base1 + ".5": col5}

        rows = {}
        for col_oid, res in col_map.items():
            for line in res.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                oid, val = parts
                if not oid.startswith(col_oid + "."):
                    continue
                idx = oid[len(col_oid) + 1:]
                if idx not in rows:
                    rows[idx] = {}
                rows[idx][col_oid] = val

        discovery = []
        seen = []
        for idx in sorted(rows.keys()):
            r = rows[idx]
            presence = r.get(base1 + ".3", "")
            state = r.get(base1 + ".4", "")
            name = r.get(base1 + ".5", "").lstrip()
            if not name.startswith("FAN"):
                continue
            if presence == "6":
                continue
            s = int(state) if state.isdigit() else 0
            if s <= 0:
                continue
            sensor_id = name.split("#")[-1]
            if sensor_id in seen:
                continue
            seen.append(sensor_id)
            discovery.append({"item": sensor_id, "params": {"lower": [3000, 2800]},
                              "metrics": ["fan_rpm"]})

        return {"changed": False, "msg": "discovered %d fan sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    col3 = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                    "-Oqv", params.get("host", "localhost"),
                    ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1.3." + item], mutates=False)
    col5 = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                    "-Oqv", params.get("host", "localhost"),
                    ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1.5." + item], mutates=False)
    if col5.rc != 0:
        return {"changed": False, "msg": "fan %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    name = col5.stdout.strip().lstrip()
    if not name.startswith("FAN"):
        return {"changed": False, "msg": "fan %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value = int(col3.stdout.strip()) if col3.stdout.strip().isdigit() else 0
    state, metrics, summary = check_fan(value, params)
    return {"changed": False,
            "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}