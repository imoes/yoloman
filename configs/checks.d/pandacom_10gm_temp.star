def main(ctx, params):
    # pandacom_10gm_temp: SNMP temperature check for 10GM modules
    # Base OID: .1.3.6.1.4.1.3652.3.3.4
    # Columns: 1.1.2 (slot), 1.1.7 (temp), 2.1.13 (warn), 2.1.14 (crit)

    if params.get("_discover"):
        # Discovery: walk the slot column to enumerate modules
        walk = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-Oqn",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.3652.3.3.4.1.1.2",
        ], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed: " + walk.stderr,
                    "data": {"discovery": []}}
        items = []
        seen = []
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            index = oid[len(".1.3.6.1.4.1.3652.3.3.4.1.1.2"):]
            if index == "" or index in seen:
                continue
            # Read the slot name for this index
            get = ctx.run([
                "snmpget",
                "-v2c",
                "-c", params.get("community", "public"),
                "-Oqv",
                params.get("host", "localhost"),
                ".1.3.6.1.4.1.3652.3.3.4.1.1.2." + index,
            ], mutates=False)
            if get.rc != 0 or not get.stdout.strip():
                continue
            slot = get.stdout.strip()
            seen.append(index)
            items.append({"item": slot, "params": {"levels": (35.0, 40.0)},
                          "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    # Check one item
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Walk the slot column to find the index matching this item (slot name)
    walk = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-Oqn",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.3652.3.3.4.1.1.2",
    ], mutates=False)
    if walk.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed: " + walk.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found_index = ""
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        index = oid[len(".1.3.6.1.4.1.3652.3.3.4.1.1.2"):]
        if index == "":
            continue
        get = ctx.run([
            "snmpget",
            "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.3652.3.3.4.1.1.2." + index,
        ], mutates=False)
        if get.rc != 0 or get.stdout.strip() != item:
            continue
        found_index = index
        break

    if found_index == "":
        return {"changed": False, "msg": "no such module: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read temperature for the matched index
    temp_res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.3652.3.3.4.1.1.7." + found_index,
    ], mutates=False)
    if temp_res.rc != 0 or not temp_res.stdout.strip():
        return {"changed": False, "msg": "failed to read temperature for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_str = temp_res.stdout.strip()
    # Strip quotes if present
    if temp_str.startswith('"') and temp_str.endswith('"'):
        temp_str = temp_str[1:-1]
    if temp_str == "" or temp_str == "NOSUCHOBJECT" or temp_str == "NOSUCHINSTANCE":
        return {"changed": False, "msg": "no temperature data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_val = 0.0
    try_val = temp_str
    # Handle possible trailing .0 or integer formatting
    dot = try_val.find(".")
    if dot >= 0:
        int_part = try_val[:dot]
        frac_part = try_val[dot+1:]
        if int_part.lstrip("-").isdigit() and (frac_part.isdigit() or frac_part == ""):
            temp_val = float(try_val)
        else:
            return {"changed": False, "msg": "invalid temperature: " + temp_str,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    else:
        if try_val.lstrip("-").isdigit():
            temp_val = float(try_val)
        else:
            return {"changed": False, "msg": "invalid temperature: " + temp_str,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read warning level
    warn_res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.3652.3.3.4.2.1.13." + found_index,
    ], mutates=False)
    dev_warn = 35.0
    if warn_res.rc == 0 and warn_res.stdout.strip() != "":
        wv = warn_res.stdout.strip()
        if wv.startswith('"') and wv.endswith('"'):
            wv = wv[1:-1]
        if wv.lstrip("-").replace(".", "", 1).isdigit():
            dev_warn = float(wv)

    # Read alarm/critical level
    crit_res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.3652.3.3.4.2.1.14." + found_index,
    ], mutates=False)
    dev_crit = 40.0
    if crit_res.rc == 0 and crit_res.stdout.strip() != "":
        cv = crit_res.stdout.strip()
        if cv.startswith('"') and cv.endswith('"'):
            cv = cv[1:-1]
        if cv.lstrip("-").replace(".", "", 1).isdigit():
            dev_crit = float(cv)

    # Get configured thresholds
    levels = params.get("levels", (35.0, 40.0))
    warn_level = dev_warn
    crit_level = dev_crit
    if type(levels) == "list" and len(levels) >= 2:
        warn_level = levels[0] if type(levels[0]) == "float" or type(levels[0]) == "int" else dev_warn
        crit_level = levels[1] if type(levels[1]) == "float" or type(levels[1]) == "int" else dev_crit
    elif type(levels) == "tuple" and len(levels) >= 2:
        warn_level = levels[0] if type(levels[0]) == "float" or type(levels[0]) == "int" else dev_warn
        crit_level = levels[1] if type(levels[1]) == "float" or type(levels[1]) == "int" else dev_crit
    # Prefer device levels if configured params are empty/default
    if warn_level == 35.0 and crit_level == 40.0:
        warn_level = dev_warn
        crit_level = dev_crit

    # Grade
    if temp_val >= crit_level:
        state = "CRIT"
    elif temp_val >= warn_level:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": item + ": %f C (levels: %f/%f C)" % (temp_val, warn_level, crit_level),
        "data": {
            "state": state,
            "metrics": {"temperature": temp_val},
            "details": "",
        },
    }