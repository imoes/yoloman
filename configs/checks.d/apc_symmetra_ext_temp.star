def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        version = params.get("version", "2c")
        ver_arg = "-v" + version

        sys = ctx.run(
            ["snmpget", ver_arg, "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False)
        if sys.rc == 127:
            return {"changed": False, "msg": "not installed",
                    "data": {"discovery": []}}
        if sys.rc != 0 or not sys.stdout:
            return {"changed": False, "msg": "no sysOID",
                    "data": {"discovery": []}}
        sysval = sys.stdout.strip()
        if not sysval.startswith(".1.3.6.1.4.1.318"):
            return {"changed": False, "msg": "not APC",
                    "data": {"discovery": []}}

        base = ".1.3.6.1.4.1.318.1.1.10.2.3.2.1"
        idx_res = ctx.run(
            ["snmpwalk", ver_arg, "-c", community, "-Oqn", "-On", host, base + ".1"],
            mutates=False)
        if idx_res.rc == 127:
            return {"changed": False, "msg": "not installed",
                    "data": {"discovery": []}}
        if idx_res.rc != 0:
            return {"changed": False, "msg": "snmpwalk idx failed",
                    "data": {"discovery": []}}

        st_res = ctx.run(
            ["snmpwalk", ver_arg, "-c", community, "-Oqn", "-On", host, base + ".3"],
            mutates=False)
        if st_res.rc != 0:
            return {"changed": False, "msg": "snmpwalk status failed",
                    "data": {"discovery": []}}

        idx_to_status = {}
        for line in idx_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            idx = oid[len(base) + 1:]
            if idx == "":
                continue
            idx_to_status[idx] = ""

        for line in st_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            val = parts[1].strip()
            idx = oid[len(base) + 1:]
            idx_to_status[idx] = val

        discovery = []
        warn = params.get("warn", 30.0)
        crit = params.get("crit", 35.0)
        for idx, status in idx_to_status.items():
            if status == "2":
                discovery.append({
                    "item": idx,
                    "params": {"levels": (warn, crit)},
                    "metrics": ["temperature"],
                })
        return {"changed": False,
                "msg": "discovered %d external temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    version = params.get("version", "2c")
    ver_arg = "-v" + version
    base = ".1.3.6.1.4.1.318.1.1.10.2.3.2.1"

    st_res = ctx.run(
        ["snmpget", ver_arg, "-c", community, "-Oqv", "-On", host, base + ".3." + item],
        mutates=False)
    tp_res = ctx.run(
        ["snmpget", ver_arg, "-c", community, "-Oqv", "-On", host, base + ".4." + item],
        mutates=False)
    un_res = ctx.run(
        ["snmpget", ver_arg, "-c", community, "-Oqv", "-On", host, base + ".5." + item],
        mutates=False)

    if st_res.rc == 127:
        return {"changed": False, "msg": "snmpget not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if st_res.rc != 0:
        return {"changed": False, "msg": "sensor %s not found in SNMP data" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = st_res.stdout.strip()
    temp_raw = tp_res.stdout.strip()
    unit_raw = un_res.stdout.strip()

    if not temp_raw.isdigit():
        return {"changed": False, "msg": "cannot parse temperature",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temp = int(temp_raw)

    if status != "2":
        return {"changed": False,
                "msg": "sensor %s not active (status %s)" % (item, status),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    unit = "c"
    if unit_raw == "2":
        unit = "f"
        temp = int((temp - 32) * 5 / 9)

    levels = params.get("levels", (30.0, 35.0))
    if type(levels) == "list":
        warn = levels[0] if len(levels) > 0 else 30.0
        crit = levels[1] if len(levels) > 1 else 35.0
    else:
        warn = params.get("warn", 30.0)
        crit = params.get("crit", 35.0)

    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "Temperature External %s: %d%s" % (item, temp, unit),
            "data": {"state": state,
                     "metrics": {"temperature": temp},
                     "details": ""}}