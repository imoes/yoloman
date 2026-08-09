def _snmp_get(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        idx = line[:sp]
        val = line[sp + 1:]
        rows.append((idx, val))
    return rows

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Detect: sysDescr must start with "Rittal LCP"
    sysdescr = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.1.0")
    if not sysdescr.startswith("Rittal LCP"):
        return {"changed": False, "msg": "not a Rittal LCP device", "data": {"discovery": []}}

    # Detect: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6 must start with "Air.Temperature.DescName"
    descname = _snmp_get(ctx, host, community, ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6")
    if not descname.startswith("Air.Temperature.DescName"):
        return {"changed": False, "msg": "not a Rittal LCP device", "data": {"discovery": []}}

    base = ".1.3.6.1.4.1.2606.7.4.2.2.1.10.2"
    oids = [
        "34", "35", "36", "37", "38", "39", "40", "41", "42", "43", "44", "45",
        "46", "47", "48", "49", "50", "51", "52", "53", "54", "55", "56", "57",
    ]

    if params.get("_discover"):
        values = []
        for oid in oids:
            v = _snmp_get(ctx, host, community, base + "." + oid)
            values.append(v)

        if not values or not values[0]:
            return {"changed": False, "msg": "no fan data", "data": {"discovery": []}}

        # Reproduce: parts = [section[0][x+1:x+4] for x in range(0, len(section[0]), 4)]
        parts = []
        i = 0
        while i < len(values):
            chunk = values[i + 1 : i + 4]
            if len(chunk) < 3:
                break
            parts.append(chunk)
            i += 4

        discovery = []
        for idx, (name, value, status) in enumerate(parts):
            if status != "off" and "FAN" in name:
                item = str(idx + 1)
                discovery.append({"item": item, "params": {}, "metrics": ["rpm"]})

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")

    values = []
    for oid in oids:
        v = _snmp_get(ctx, host, community, base + "." + oid)
        values.append(v)

    if not values or not values[0]:
        return {
            "changed": False,
            "msg": "no fan data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "LCP fan data not available"},
        }

    # lowlevel = int(re.sub(" .*$", "", section[0][0]))
    first_val = values[0]
    sp = first_val.find(" ")
    lowlevel_str = first_val if sp == -1 else first_val[:sp]
    lowlevel = int(lowlevel_str) if lowlevel_str.lstrip("-").isdigit() else 0

    # parts = [section[0][x+1:x+4] for x in range(0, len(section[0]), 4)]
    parts = []
    i = 0
    while i < len(values):
        chunk = values[i + 1 : i + 4]
        if len(chunk) < 3:
            break
        parts.append(chunk)
        i += 4

    found = False
    for idx, (name, value, status) in enumerate(parts):
        if str(idx) == item:
            found = True
            # rpm_r, unit = value.split(" ", 1)
            sp = value.find(" ")
            if sp == -1:
                rpm_str = value
                unit = ""
            else:
                rpm_str = value[:sp]
                unit = value[sp + 1:]

            rpm = int(rpm_str) if rpm_str.lstrip("-").isdigit() else 0

            if status == "OK" and rpm >= lowlevel:
                state = "OK"
                sym = ""
            elif status == "OK" and rpm < lowlevel:
                state = "WARN"
                sym = "(!)"
            else:
                state = "CRIT"
                sym = "(!!)"

            info_text = "%s RPM: %d%s (limit %d%s)%s, Status %s" % (
                name, rpm, unit, lowlevel, unit, sym, status,
            )

            return {
                "changed": False,
                "msg": info_text,
                "data": {
                    "state": state,
                    "metrics": {"rpm": rpm},
                    "details": "",
                },
            }

    if not found:
        return {
            "changed": False,
            "msg": "item not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no fan matching item %s" % item},
        }

    return {
        "changed": False,
        "msg": "unexpected state",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }