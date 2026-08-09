def _parse_fan_percent(value):
    cleaned = value.strip().replace("[\"%]", " ").replace("%", " ")
    parts = cleaned.split(" ")
    for p in parts:
        if p != "":
            if p.lstrip("-").isdigit():
                return int(p)
            return 0
    return 0

def _grade_levels(value, levels_upper, levels_lower):
    state = "OK"
    if levels_upper != None:
        warn_high, crit_high = levels_upper[0], levels_upper[1]
        if value >= crit_high:
            state = "CRIT"
        elif value >= warn_high:
            state = "WARN"
    if levels_lower != None:
        warn_low, crit_low = levels_lower[0], levels_lower[1]
        if value <= crit_low:
            state = "CRIT"
        elif value <= warn_low:
            state = "WARN"
    return state

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels")
    levels_lower = params.get("levels_lower", (28.0, 25.0))

    sys_descr = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Ovq",
        host, ".1.3.6.1.2.1.1.1.0",
    ], mutates=False)
    descr = sys_descr.stdout.strip()
    if sys_descr.rc != 0 or (not descr.endswith("mips") and not descr.endswith("sh4a")):
        return {"changed": False, "msg": "IBM IMM not detected on this host",
                "data": {"discovery": [], "host_labels": {}}}

    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, ".1.3.6.1.4.1.2.3.51.3.1.3.2.1.2",
        ], mutates=False)
        names = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(".1.3.6.1.4.1.2.3.51.3.1.3.2.1.2") + 1:]
            names[idx] = parts[1]
        res2 = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, ".1.3.6.1.4.1.2.3.51.3.1.3.2.1.3",
        ], mutates=False)
        out = []
        for line in res2.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(".1.3.6.1.4.1.2.3.51.3.1.3.2.1.3") + 1:]
            speed_text = parts[1]
            name = names.get(idx)
            if name == None:
                continue
            if speed_text.lower() == "offline":
                continue
            out.append({
                "item": name,
                "params": {"levels": levels, "levels_lower": levels_lower},
                "metrics": ["fan_speed_percent"],
            })
        return {"changed": False,
                "msg": "discovered %d fan items" % len(out),
                "data": {"discovery": out, "host_labels": {"cmk/hw_fans_present": "yes"}}}

    item = params.get("item", "")
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Ovq",
        host, ".1.3.6.1.4.1.2.3.51.3.1.3.2.1.3." + item,
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no such fan item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    speed_text = res.stdout.strip()
    low = speed_text.lower()
    if low in ["offline", "unavailable"]:
        return {"changed": False, "msg": "is " + low,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    rpm_perc = _parse_fan_percent(speed_text)
    state = _grade_levels(rpm_perc, levels, levels_lower)
    return {"changed": False,
            "msg": "%f%% of max RPM" % rpm_perc,
            "data": {"state": state, "metrics": {"fan_speed_percent": rpm_perc},
                     "details": ""}}