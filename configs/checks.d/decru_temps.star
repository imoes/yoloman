def fahrenheit_to_celsius(f):
    return (f - 32.0) * 5.0 / 9.0

def grade_temperature(value, levels):
    if value == None:
        return "UNKNOWN"
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Detect the real product first (DETECT_DECRU = sysDescr contains "datafort")
    sysdesc = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if sysdesc.rc != 0 or "datafort" not in sysdesc.stdout:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "no Decru/DataFort device found",
                "data": {"discovery": [], "host_labels": {}},
            }
        return {
            "changed": False,
            "msg": "no Decru/DataFort device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if params.get("_discover"):
        # Walk the table at base .1.3.6.1.4.1.12962.1.2.4.1
        # col 2 = sensor name, col 3 = temperature (F)
        name_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-m", "",
             host, ".1.3.6.1.4.1.12962.1.2.4.1.2"],
            mutates=False,
        )
        temp_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-m", "",
             host, ".1.3.6.1.4.1.12962.1.2.4.1.3"],
            mutates=False,
        )
        if name_res.rc != 0 and not name_res.stdout:
            return {
                "changed": False,
                "msg": "no Decru temperature sensors found",
                "data": {"discovery": [], "host_labels": {}},
            }

        names = {}
        for line in name_res.stdout.splitlines():
            space = line.find(" ")
            if space == -1:
                continue
            oid = line[:space]
            val = line[space + 1:]
            idx = oid[len(".1.3.6.1.4.1.12962.1.2.4.1.2") + 1:]
            names[idx] = val

        temps = {}
        for line in temp_res.stdout.splitlines():
            space = line.find(" ")
            if space == -1:
                continue
            oid = line[:space]
            val = line[space + 1:]
            idx = oid[len(".1.3.6.1.4.1.12962.1.2.4.1.3") + 1:]
            temps[idx] = val

        discovery = []
        for idx in names:
            name = names[idx]
            rawtemp = temps.get(idx)
            if rawtemp == None:
                continue
            temp_f = float(rawtemp)
            temp_c = int(fahrenheit_to_celsius(temp_f))
            discovery.append({
                "item": name,
                "metrics": ["temperature"],
                "params": {"levels": (temp_c + 4, temp_c + 8)},
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    item = params.get("item", "")
    levels = params.get("levels", None)
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", "-m", "",
         host, ".1.3.6.1.4.1.12962.1.2.4.1.2." + item],
        mutates=False,
    )
    # We need to match by name, not index; re-query both columns per index.
    # Walk both columns and find the matching name.
    name_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-m", "",
         host, ".1.3.6.1.4.1.12962.1.2.4.1.2"],
        mutates=False,
    )
    temp_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-m", "",
         host, ".1.3.6.1.4.1.12962.1.2.4.1.3"],
        mutates=False,
    )
    names = {}
    for line in name_res.stdout.splitlines():
        space = line.find(" ")
        if space == -1:
            continue
        oid = line[:space]
        val = line[space + 1:]
        idx = oid[len(".1.3.6.1.4.1.12962.1.2.4.1.2") + 1:]
        names[idx] = val

    temps = {}
    for line in temp_res.stdout.splitlines():
        space = line.find(" ")
        if space == -1:
            continue
        oid = line[:space]
        val = line[space + 1:]
        idx = oid[len(".1.3.6.1.4.1.12962.1.2.4.1.3") + 1:]
        temps[idx] = val

    if levels == None:
        # Use inventory-time +4/+8 from the data, same as discovery
        found_c = None
        for idx in names:
            if names[idx] == item:
                rawtemp = temps.get(idx)
                if rawtemp != None:
                    found_c = int(fahrenheit_to_celsius(float(rawtemp)))
                break
        if found_c == None:
            return {
                "changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        levels = (found_c + 4, found_c + 8)

    rawtemp = None
    for idx in names:
        if names[idx] == item:
            rawtemp = temps.get(idx)
            break

    if rawtemp == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    temp_f = float(rawtemp)
    temp_c = fahrenheit_to_celsius(temp_f)
    state = grade_temperature(temp_c, levels)
    return {
        "changed": False,
        "msg": "Temperature %s: %f C" % (item, temp_c),
        "data": {
            "state": state,
            "metrics": {"temperature": temp_c},
            "details": "",
        },
    }