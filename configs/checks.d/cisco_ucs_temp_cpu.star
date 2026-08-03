def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    levels = params.get("levels", (75.0, 85.0))
    warn = levels[0]
    crit = levels[1]

    # The SNMP table at .1.3.6.1.4.1.9.9.719.1.41.2.1 has:
    #   column .2 = cucsProcessorEnvStatsName (cpu Unit Name)
    #   column .10 = cucsProcessorEnvStatsTemperature
    base = ".1.3.6.1.4.1.9.9.719.1.41.2.1"
    name_oid = base + ".2"
    temp_oid = base + ".10"

    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, temp_oid], mutates=False)
        rows = res.stdout.split("\n")
        items = []
        for line in rows:
            line = line.strip()
            if line == "":
                continue
            idx = line.find(" ")
            if idx < 0:
                continue
            oid = line[:idx]
            value = line[idx + 1:]
            # index is the suffix after the column base
            idx2 = oid.find(temp_oid + ".")
            if idx2 < 0:
                continue
            index = oid[idx2 + len(temp_oid) + 1:]
            if index == "":
                continue
            # fetch the cpu Unit Name for this index
            r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-On", host, name_oid + "." + index], mutates=False)
            if r.rc != 0:
                continue
            name = r.stdout.strip()
            if name == "":
                continue
            # The Checkmk parse function splits name on "/" and takes part [3] as the item
            parts = name.split("/")
            if len(parts) < 4:
                item_name = name
            else:
                item_name = parts[3]
            items.append({"item": item_name, "params": {"levels": levels}, "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d items" % len(items), "data": {"discovery": items}}

    # Check mode for a single item
    # We need to correlate item name -> temperature. Re-walk temp column and name column,
    # then match by the item name (parts[3] of cpu Unit Name).
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, temp_oid], mutates=False)
    rows = res.stdout.split("\n")
    temps = {}
    for line in rows:
        line = line.strip()
        if line == "":
            continue
        idx = line.find(" ")
        if idx < 0:
            continue
        oid = line[:idx]
        value = line[idx + 1:]
        idx2 = oid.find(temp_oid + ".")
        if idx2 < 0:
            continue
        index = oid[idx2 + len(temp_oid) + 1:]
        if index == "":
            continue
        r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-On", host, name_oid + "." + index], mutates=False)
        if r.rc != 0:
            continue
        name = r.stdout.strip()
        if name == "":
            continue
        parts = name.split("/")
        if len(parts) < 4:
            item_name = name
        else:
            item_name = parts[3]
        if value == "":
            continue
        temps[item_name] = value

    if item not in temps:
        return {"changed": False, "msg": "no temperature for CPU " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_str = temps[item]
    # Strip any type tag just in case
    temp_str = temp_str.strip()
    # Remove surrounding quotes if present
    if len(temp_str) >= 2 and temp_str[0] == '"' and temp_str[-1] == '"':
        temp_str = temp_str[1:-1]
    if len(temp_str) >= 2 and temp_str[0] == "'" and temp_str[-1] == "'":
        temp_str = temp_str[1:-1]
    if not temp_str.replace(".", "", 1).replace("-", "", 1).isdigit():
        return {"changed": False, "msg": "invalid temperature value: " + temp_str, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temp = float(temp_str)

    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False, "msg": "CPU %s temperature: %f C" % (item, temp), "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}