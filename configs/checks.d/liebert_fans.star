def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    oid_base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    oid_suffix = "1.2.1.5077"
    oid_name = oid_base + ".10." + oid_suffix
    oid_value = oid_base + ".20." + oid_suffix
    oid_unit = oid_base + ".30." + oid_suffix

    # Parse levels with defaults
    lvls = params.get("levels", None)
    if lvls == None:
        warn_default = 80.0
        crit_default = 90.0
    elif type(lvls) == "list" and len(lvls) >= 2:
        warn_default = float(lvls[0])
        crit_default = float(lvls[1])
    elif type(lvls) == "list" and len(lvls) == 1:
        warn_default = float(lvls[0])
        crit_default = 90.0
    else:
        warn_default = 80.0
        crit_default = 90.0

    if params.get("_discover"):
        sys_res = ctx.run(
            ["snmpget", "-v" + version, "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_res.rc != 0:
            return {"changed": False, "msg": "no SNMP response", "data": {"discovery": []}}

        sys_oid = sys_res.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.476.1.42"):
            return {"changed": False, "msg": "not a Liebert device", "data": {"discovery": []}}

        name_res = ctx.run(["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid_name], mutates=False)
        if name_res.rc != 0:
            return {"changed": False, "msg": "no Liebert fan data found", "data": {"discovery": []}}

        fan_name = name_res.stdout.strip()
        if fan_name.startswith('"') and fan_name.endswith('"') and len(fan_name) >= 2:
            fan_name = fan_name[1:-1]

        if not fan_name:
            return {"changed": False, "msg": "empty fan name", "data": {"discovery": []}}

        discovery = [{
            "item": fan_name,
            "params": {"levels": [warn_default, crit_default]},
            "metrics": ["fan_perc"],
            "service_labels": {"snmp_device": host},
        }]
        return {"changed": False, "msg": "discovered 1 fan", "data": {"discovery": discovery}}

    item = params.get("item", "")

    name_res = ctx.run(["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid_name], mutates=False)
    value_res = ctx.run(["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid_value], mutates=False)
    unit_res = ctx.run(["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid_unit], mutates=False)

    if name_res.rc != 0 or value_res.rc != 0 or unit_res.rc != 0:
        return {
            "changed": False,
            "msg": "no Liebert fan data available (SNMP error)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    fan_name = name_res.stdout.strip()
    if fan_name.startswith('"') and fan_name.endswith('"') and len(fan_name) >= 2:
        fan_name = fan_name[1:-1]

    fan_value_str = value_res.stdout.strip()
    fan_unit = unit_res.stdout.strip()

    if fan_name.startswith('"') and fan_name.endswith('"') and len(fan_name) >= 2:
        fan_name = fan_name[1:-1]

    if item != "" and fan_name != item:
        return {
            "changed": False,
            "msg": "item '" + item + "' not found, got '" + fan_name + "'",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not fan_value_str:
        return {
            "changed": False,
            "msg": "no fan value returned",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Strip potential SNMP type prefix (shouldn't happen with -Oqv)
    clean_val = fan_value_str.strip()
    colon_idx = clean_val.find(": ")
    if colon_idx >= 0:
        clean_val = clean_val[colon_idx + 2:]

    clean_val = clean_val.strip()

    # Parse numeric value
    parsed_ok = True
    numeric_value = 0.0
    if clean_val.lstrip("-").isdigit():
        numeric_value = float(int(clean_val))
    else:
        parts = clean_val.lstrip("-").split(".")
        is_float = False
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            is_float = True
        elif len(parts) == 1 and parts[0].isdigit():
            is_float = True
        elif len(parts) == 1 and parts[0] == "":
            is_float = False
        if is_float:
            numeric_value = float(clean_val)
        else:
            parsed_ok = False

    if not parsed_ok:
        return {
            "changed": False,
            "msg": "could not parse fan value: '" + fan_value_str + "'",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Use params levels if provided, otherwise defaults
    params_levels = params.get("levels", None)
    if params_levels != None and type(params_levels) == "list" and len(params_levels) >= 2:
        warn = float(params_levels[0])
        crit = float(params_levels[1])
    else:
        warn = warn_default
        crit = crit_default

    if numeric_value >= crit:
        state = "CRIT"
    elif numeric_value >= warn:
        state = "WARN"
    else:
        state = "OK"

    rendered_val = "%f" % numeric_value
    summary = rendered_val + " " + fan_unit

    return {
        "changed": False,
        "msg": fan_name + " " + summary,
        "data": {
            "state": state,
            "metrics": {"fan_perc": numeric_value},
            "details": fan_name + " at " + summary,
        },
    }