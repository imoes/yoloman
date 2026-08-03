def _isilon_power_item_name(sensor_name):
    return sensor_name.replace("Voltage", "").replace("  ", " ").strip()

def _strip_type_prefix(value):
    # snmpget -Oqv should give bare value, but guard against a stray type tag
    idx = value.find(": ")
    if idx >= 0:
        return value[idx + 2:]
    return value

def main(ctx, params):
    if params.get("_discover"):
        # Probe: Isilon systems expose their identity and power sensors via SNMP.
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        version = params.get("version", "2c")
        base = ".1.3.6.1.4.1.12124.2.55.1"

        # First confirm the target is an Isilon system via sysDescr (DETECT_ISILON)
        sysdesc = ctx.run(["snmpget", "-" + version, "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sysdesc.rc != 0 or sysdesc.skipped:
            return {"changed": False, "msg": "not an Isilon system (snmp unreachable)", "data": {"discovery": []}}
        sysdesc_str = _strip_type_prefix(sysdesc.stdout).strip()
        if "isilon" not in sysdesc_str.lower():
            return {"changed": False, "msg": "not an Isilon system", "data": {"discovery": []}}

        # Walk the power sensor table: column OID .3 = sensor name, .4 = voltage
        name_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".3"], mutates=False)
        volt_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".4"], mutates=False)
        if name_walk.rc != 0 or volt_walk.rc != 0:
            return {"changed": False, "msg": "failed to walk Isilon power sensors", "data": {"discovery": []}}

        names_by_index = {}
        for line in name_walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = _strip_type_prefix(line[sp + 1:]).strip().strip('"')
            index = oid[len(base + ".3") + 1:]
            if index:
                names_by_index[index] = val

        volts_by_index = {}
        for line in volt_walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = _strip_type_prefix(line[sp + 1:]).strip().strip('"')
            index = oid[len(base + ".4") + 1:]
            if index:
                volts_by_index[index] = val

        discovery = []
        seen_items = []
        for index in sorted(names_by_index.keys()):
            name_val = names_by_index.get(index, "")
            if "Power Supply" not in name_val and "PS" not in name_val:
                continue
            item = _isilon_power_item_name(name_val)
            if item in seen_items:
                continue
            seen_items.append(item)
            discovery.append({
                "item": item,
                "params": {"levels_lower": [0.5, 0.0]},
                "metrics": ["voltage"],
            })

        return {"changed": False, "msg": "discovered %d Isilon power sensors" % len(discovery), "data": {"discovery": discovery, "host_labels": {"cmk/os_family": "emc_isilon"}}}

    # CHECK MODE
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    version = params.get("version", "2c")
    base = ".1.3.6.1.4.1.12124.2.55.1"
    item = params.get("item", "")

    # Verify Isilon identity
    sysdesc = ctx.run(["snmpget", "-" + version, "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if sysdesc.rc != 0 or sysdesc.skipped:
        return {"changed": False, "msg": "not an Isilon system (snmp unreachable)", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysdesc_str = _strip_type_prefix(sysdesc.stdout).strip()
    if "isilon" not in sysdesc_str.lower():
        return {"changed": False, "msg": "not an Isilon system", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Walk names to find the index matching this item
    name_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".3"], mutates=False)
    if name_walk.rc != 0:
        return {"changed": False, "msg": "failed to walk Isilon power sensors", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_index = None
    match_name = None
    for line in name_walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = _strip_type_prefix(line[sp + 1:]).strip().strip('"')
        index = oid[len(base + ".3") + 1:]
        if not index:
            continue
        if _isilon_power_item_name(val) == item:
            target_index = index
            match_name = val
            break

    if target_index == None:
        return {"changed": False, "msg": "no such Isilon power sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get the voltage for the matched index
    volt_get = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".4." + target_index], mutates=False)
    if volt_get.rc != 0:
        return {"changed": False, "msg": "failed to read voltage for sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw_volt = _strip_type_prefix(volt_get.stdout).strip().strip('"')
    if not raw_volt.replace(".", "").isdigit():
        return {"changed": False, "msg": "invalid voltage value for sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    volt = float(raw_volt)

    infotext = "%f V" % volt

    levels_lower = params.get("levels_lower", [0.5, 0.0])
    warn_lower = levels_lower[0] if len(levels_lower) > 0 else 0.5
    crit_lower = levels_lower[1] if len(levels_lower) > 1 else 0.0

    levels_upper = params.get("levels_upper", None)
    if levels_upper != None and len(levels_upper) >= 2:
        warn_upper = levels_upper[0]
        crit_upper = levels_upper[1]
    else:
        warn_upper = None
        crit_upper = None

    lower_text = " (warn/crit below %f/%f V)" % (warn_lower, crit_lower)
    if warn_upper != None and crit_upper != None:
        upper_text = " (warn/crit at or above %f/%f V)" % (warn_upper, crit_upper)
    else:
        upper_text = ""

    if volt < crit_lower:
        state = "CRIT"
        infotext += lower_text
    elif crit_upper != None and volt >= crit_upper:
        state = "CRIT"
        infotext += upper_text
    elif volt < warn_lower:
        state = "WARN"
        infotext += lower_text
    elif warn_upper != None and volt >= warn_upper:
        state = "WARN"
        infotext += upper_text
    else:
        state = "OK"

    return {"changed": False, "msg": infotext, "data": {"state": state, "metrics": {"voltage": volt}, "details": ""}}