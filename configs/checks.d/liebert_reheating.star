def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels", (80, 90))

    # Probe for the real Liebert device before reporting anything.
    sys_oid = ".1.3.6.1.2.1.1.2.0"
    probe = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, sys_oid],
        mutates=False,
    )
    if probe.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no Liebert device found on %s" % host,
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no Liebert device found on %s" % host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sys_res = probe.stdout.strip()
    # DETECT_LIEBERT = startswith(".1.3.6.1.2.1.1.2.0", ".1.3.6.1.4.1.476.1.42")
    if not sys_res.startswith(".1.3.6.1.4.1.476.1.42"):
        if params.get("_discover"):
            return {"changed": False, "msg": "no Liebert device found on %s" % host,
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no Liebert device found on %s" % host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    name_oid = base + ".10.1.2.1.5080"
    value_oid = base + ".20.1.2.1.5080"
    unit_oid = base + ".30.1.2.1.5080"

    if params.get("_discover"):
        nm = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, name_oid],
            mutates=False,
        )
        if nm.rc != 0:
            return {"changed": False, "msg": "no Liebert reheating data found",
                    "data": {"discovery": []}}
        raw_name = nm.stdout.strip().strip('"')
        if not raw_name:
            return {"changed": False, "msg": "no Liebert reheating name found",
                    "data": {"discovery": []}}
        items = []
        if "Reheat" in raw_name:
            items.append({
                "item": raw_name,
                "params": {"levels": list(levels)},
                "metrics": ["fan_perc"],
            })
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")

    nm = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, name_oid],
        mutates=False,
    )
    vm = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, value_oid],
        mutates=False,
    )
    um = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, unit_oid],
        mutates=False,
    )

    if nm.rc != 0 or vm.rc != 0 or um.rc != 0:
        return {"changed": False, "msg": "no Liebert reheating data found for item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_name = nm.stdout.strip().strip('"')
    if not ("Reheat" in raw_name):
        return {"changed": False, "msg": "no reheat utilization found for item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    try_value = vm.stdout.strip()
    value = float(try_value) if _is_floatable(try_value) else None
    if value == None:
        return {"changed": False, "msg": "could not parse reheating value: %s" % try_value,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    unit = um.stdout.strip().strip('"')

    warn = levels[0] if len(levels) >= 1 else 80
    crit = levels[1] if len(levels) >= 2 else 90

    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    else:
        state = "OK"

    render = "%f %s" % (value, unit)
    return {"changed": False, "msg": "Reheating Utilization: %s" % render,
            "data": {"state": state, "metrics": {"fan_perc": value}, "details": render}}


def _is_floatable(s):
    stripped = s
    neg = False
    if len(stripped) > 0 and stripped[0] == "-":
        neg = True
        stripped = stripped[1:]
    if len(stripped) == 0:
        return False
    if stripped == ".":
        return False
    digits = stripped
    if "." in digits:
        parts = digits.split(".")
        if len(parts) != 2:
            return False
        int_part = parts[0]
        frac_part = parts[1]
        if len(int_part) == 0 and len(frac_part) == 0:
            return False
        if len(int_part) > 0 and not int_part.isdigit():
            return False
        if len(frac_part) > 0 and not frac_part.isdigit():
            return False
        return True
    return stripped.isdigit()