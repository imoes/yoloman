def main(ctx, params):
    BASE_OID = ".1.3.6.1.4.1.2.3.51.3.1.1.2.1"
    COL_ITEM = "2"
    COL_TEMP = "3"
    COL_DEV_CRIT = "6"
    COL_DEV_WARN = "7"
    COL_DEV_CRIT_LOWER = "9"
    COL_DEV_WARN_LOWER = "10"

    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real thing: IBM IMM detection via sysDescr
    sys_descr = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host,
        ".1.3.6.1.2.1.1.1.0",
    ], mutates=False)

    if sys_descr.rc != 0 or sys_descr.stdout == "":
        if sys_descr.rc == 127:
            return {"changed": False, "msg": "snmpget not found / not installed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if params.get("_discover"):
            return {"changed": False, "msg": "IBM IMM not detected on this host",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "IBM IMM not detected (sysDescr unavailable)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    descr = sys_descr.stdout.strip()
    is_imm = descr.endswith("mips") or descr.endswith("sh4a")

    if not is_imm:
        if params.get("_discover"):
            return {"changed": False, "msg": "IBM IMM not detected on this host",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "IBM IMM not detected (sysDescr does not match)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Discovery mode: walk the sensor table
    if params.get("_discover"):
        col_oid = BASE_OID + "." + COL_ITEM
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn", host,
            col_oid,
        ], mutates=False)

        if res.rc != 0:
            return {"changed": False, "msg": "IBM IMM temperature sensor table not reachable",
                    "data": {"discovery": []}}

        out = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            line_oid = parts[0]
            value = parts[1].strip()

            idx = line_oid[len(col_oid) + 1:]

            temp_oid = BASE_OID + "." + COL_TEMP + "." + idx
            temp_res = ctx.run([
                "snmpget", "-v2c", "-c", community, "-Oqv", host,
                temp_oid,
            ], mutates=False)

            if temp_res.rc != 0 or temp_res.stdout == "":
                continue

            temp_str = temp_res.stdout.strip()
            if not _is_float(temp_str):
                continue

            temp = float(temp_str)

            if temp != 0.0:
                out.append({
                    "item": value,
                    "params": {"levels_lower": params.get("levels_lower", (None, None))},
                    "metrics": ["temperature"],
                    "service_labels": {"ibm_imm_sensor": value},
                })

        return {"changed": False, "msg": "discovered %d temperature sensors" % len(out),
                "data": {"discovery": out}}

    # Check mode: check one item
    item = params.get("item", "")

    col_oid = BASE_OID + "." + COL_ITEM
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host,
        col_oid,
    ], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "IBM IMM temperature sensor table not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item_index = None
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        line_oid = parts[0]
        value = parts[1].strip()
        idx = line_oid[len(col_oid) + 1:]
        if value == item:
            item_index = idx
            break

    if item_index == None:
        return {"changed": False, "msg": "sensor '%s' not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read temperature
    temp_oid = BASE_OID + "." + COL_TEMP + "." + item_index
    temp_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host,
        temp_oid,
    ], mutates=False)

    if temp_res.rc != 0 or temp_res.stdout == "":
        return {"changed": False, "msg": "temperature value unavailable for sensor '%s'" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_str = temp_res.stdout.strip()
    if not _is_float(temp_str):
        return {"changed": False, "msg": "invalid temperature value for sensor '%s'" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temperature = float(temp_str)

    # Read device levels (upper: warn/crit)
    dev_warn_oid = BASE_OID + "." + COL_DEV_WARN + "." + item_index
    dev_crit_oid = BASE_OID + "." + COL_DEV_CRIT + "." + item_index
    dev_warn_lower_oid = BASE_OID + "." + COL_DEV_WARN_LOWER + "." + item_index
    dev_crit_lower_oid = BASE_OID + "." + COL_DEV_CRIT_LOWER + "." + item_index

    dev_warn_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, dev_warn_oid,
    ], mutates=False)
    dev_crit_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, dev_crit_oid,
    ], mutates=False)
    dev_warn_lower_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, dev_warn_lower_oid,
    ], mutates=False)
    dev_crit_lower_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, dev_crit_lower_oid,
    ], mutates=False)

    upper_dev_levels = None
    lower_dev_levels = None

    dw = dev_warn_res.stdout.strip()
    dc = dev_crit_res.stdout.strip()
    if _is_float(dw) and _is_float(dc):
        upper_dev_levels = (float(dw), float(dc))

    dwl = dev_warn_lower_res.stdout.strip()
    dcl = dev_crit_lower_res.stdout.strip()
    if _is_float(dwl) and _is_float(dcl):
        lower_dev_levels = (float(dwl), float(dcl))

    # Get user-configured levels (Checkmk temperature ruleset default)
    levels_lower = params.get("levels_lower", (None, None))
    warn = params.get("levels", (80, 90))
    user_warn = warn[0] if len(warn) >= 2 else 80
    user_crit = warn[1] if len(warn) >= 2 else 90

    # Apply check_temperature logic: device levels override user levels
    state = _grade_temperature(
        temperature, user_warn, user_crit, upper_dev_levels, lower_dev_levels,
        levels_lower,
    )

    details = "Sensor: %s, Temperature: %f C" % (item, temperature)
    if upper_dev_levels != None:
        details += " (device levels: warn=%f, crit=%f)" % (upper_dev_levels[0], upper_dev_levels[1])
    if lower_dev_levels != None:
        details += " (device lower levels: warn=%f, crit=%f)" % (lower_dev_levels[0], lower_dev_levels[1])

    return {"changed": False, "msg": details,
            "data": {"state": state, "metrics": {"temperature": temperature}, "details": details}}


def _is_float(s):
    if s == None or s == "":
        return False
    if s.startswith("-"):
        s = s[1:]
    if "." in s:
        parts = s.split(".", 1)
        if len(parts) != 2:
            return False
        return parts[0].isdigit() and parts[1].isdigit()
    return s.isdigit()


def _grade_temperature(temperature, user_warn, user_crit, upper_dev_levels, lower_dev_levels, levels_lower):
    # Device upper levels take precedence over user levels when present
    if upper_dev_levels != None:
        dev_warn, dev_crit = upper_dev_levels
        if temperature >= dev_crit:
            return "CRIT"
        elif temperature >= dev_warn:
            return "WARN"

    if lower_dev_levels != None:
        dev_warn_lower, dev_crit_lower = lower_dev_levels
        if temperature <= dev_crit_lower:
            return "CRIT"
        elif temperature <= dev_warn_lower:
            return "WARN"

    # User-configured lower levels (levels_lower)
    lw_warn = levels_lower[0] if len(levels_lower) >= 2 else None
    lw_crit = levels_lower[1] if len(levels_lower) >= 2 else None
    if lw_warn != None and lw_crit != None:
        if temperature <= lw_crit:
            return "CRIT"
        elif temperature <= lw_warn:
            return "WARN"

    # Fall back to user-configured upper levels
    if temperature >= user_crit:
        return "CRIT"
    elif temperature >= user_warn:
        return "WARN"

    return "OK"