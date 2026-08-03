def main(ctx, params):
    # ---- discovery mode ----
    if params.get("_discover"):
        sys_oid = _snmp_get(ctx, params, ".1.3.6.1.2.1.1.2.0")
        if sys_oid == None:
            return {"changed": False, "msg": "no GUDE device found",
                    "data": {"discovery": []}}
        is_gude = False
        for prefix in [".1.3.6.1.4.1.28507.19", ".1.3.6.1.4.1.28507.38",
                       ".1.3.6.1.4.1.28507.66", ".1.3.6.1.4.1.28507.67"]:
            if sys_oid.startswith(prefix):
                is_gude = True
                break
        if not is_gude:
            return {"changed": False, "msg": "no GUDE humidity device found",
                    "data": {"discovery": []}}

        section = _fetch_section(ctx, params)
        out = []
        for name in sorted(section.keys()):
            reading = section[name]
            if reading != -999.9:
                out.append({"item": name,
                            "params": {"levels_lower": (0.0, 0.0),
                                       "levels": (60.0, 70.0)},
                            "metrics": ["humidity"]})
        return {"changed": False,
                "msg": "discovered %d humidity sensors" % len(out),
                "data": {"discovery": out}}

    # ---- check mode ----
    item = params.get("item", "")
    section = _fetch_section(ctx, params)
    reading = section.get(item)
    if reading == None:
        return {"changed": False, "msg": item + " not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if reading == -999.9:
        return {"changed": False, "msg": item + " reading unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", (60.0, 70.0))
    warn = levels[0]
    crit = levels[1]

    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": item + ": %f%%" % reading,
            "data": {"state": state, "metrics": {"humidity": reading},
                     "details": ""}}


def _snmp_get(ctx, params, oid):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                  mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return None
    return res.stdout.strip()


def _snmpwalk(ctx, params, oid):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
                  mutates=False)
    return res.stdout if res.rc == 0 else ""


def _fetch_section(ctx, params):
    section = {}
    tables = ["19", "38", "66", "67"]
    for table in tables:
        base = ".1.3.6.1.4.1.28507." + table + ".1.6.1.1"
        out = _snmpwalk(ctx, params, base)
        for line in out.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0]
            reading_str = parts[1]
            idx = oid_full[len(base) + 1:]
            digits = reading_str.replace("-", "").replace(".", "")
            if digits.isdigit():
                val = float(reading_str) / 10.0
            else:
                continue
            section["Sensor " + idx] = val
    return section