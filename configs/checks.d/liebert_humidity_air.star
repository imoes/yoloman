def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"

    # Probe for the Liebert device presence via sysObjectID detection.
    sys_oid = ".1.3.6.1.2.1.1.2.0"
    probe = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, sys_oid],
        mutates=False,
    )
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "snmpget not found: Liebert device not monitored",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "snmpget binary not available",
            },
        }
    if probe.skipped:
        return {
            "changed": False,
            "msg": "would query Liebert device via SNMP",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    sys_res = probe.stdout.strip()
    if probe.rc != 0 or not sys_res.startswith(".1.3.6.1.4.1.476.1.42"):
        return {
            "changed": False,
            "msg": "not a Liebert device",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "sysObjectID does not match Liebert enterprise OID",
            },
        }

    # Walk the flexible entry table for humidity labels/values/units.
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
        mutates=False,
    )
    if walk.rc != 0 or walk.skipped:
        return {
            "changed": False,
            "msg": "SNMP walk failed for Liebert humidity table",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "could not retrieve liebert_humidity_air section",
            },
        }

    entries = {}
    for line in walk.stdout.splitlines():
        space = line.find(" ")
        if space == -1:
            continue
        oid = line[:space]
        val = line[space + 1:]
        suffix = oid[len(base_oid) + 1:]
        parts = suffix.split(".")
        if len(parts) < 4:
            continue
        col = parts[0]
        instance = parts[3]
        if instance not in entries:
            entries[instance] = {}
        entries[instance][col] = val

    parsed = {}
    labels = {}
    values = {}
    units = {}
    for instance in sorted(entries.keys()):
        e = entries[instance]
        if "10" in e and "20" in e and "30" in e:
            parsed[e["10"]] = (e["20"], e["30"])

    section = {}
    used_names = {}
    for key, (value, unit) in parsed.items():
        name = key
        if name in used_names:
            count = used_names[name] + 1
            used_names[name] = count
            name = "%s %d" % (key, count)
        else:
            used_names[name] = 0
        section[name] = (value, unit)

    device_state = None

    if params.get("_discover"):
        discovery = []
        for key, (value, _unit) in section.items():
            if "Unavailable" not in value:
                item = key.replace(" Humidity", "")
                discovery.append({
                    "item": item,
                    "params": {
                        "levels": (50.0, 55.0),
                        "levels_lower": (10.0, 15.0),
                    },
                    "metrics": ["humidity"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    full_key = item + " Humidity"
    value = None
    unit = ""
    for key, (v, u) in section.items():
        if key.replace(" Humidity", "") == item:
            value = v
            unit = u
            break

    if value == None:
        return {
            "changed": False,
            "msg": "no such item: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "item '%s' not found in liebert_humidity_air section" % item,
            },
        }

    if "Unavailable" in value and device_state == "standby":
        return {
            "changed": False,
            "msg": "Unit is in standby (unavailable)",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": "",
            },
        }

    if not value.replace(".", "").replace("-", "").isdigit():
        return {
            "changed": False,
            "msg": "cannot parse value: %s" % value,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "value is not numeric",
            },
        }

    fval = float(value)
    warn_upper = params.get("levels", (50.0, 55.0))
    crit_upper = warn_upper[1] if len(warn_upper) >= 2 else warn_upper[0]
    warn_upper_val = warn_upper[0] if len(warn_upper) >= 1 else 50.0

    warn_lower = params.get("levels_lower", (10.0, 15.0))
    crit_lower = warn_lower[1] if len(warn_lower) >= 2 else warn_lower[0]
    warn_lower_val = warn_lower[0] if len(warn_lower) >= 1 else 10.0

    state = "OK"
    if fval >= warn_upper_val:
        state = "WARN"
    if fval >= crit_upper:
        state = "CRIT"
    if fval <= warn_lower_val:
        if state == "OK":
            state = "WARN"
    if fval <= crit_lower:
        state = "CRIT"

    return {
        "changed": False,
        "msg": "%s %f %s" % (item, fval, unit),
        "data": {
            "state": state,
            "metrics": {"humidity": fval},
            "details": "",
        },
    }