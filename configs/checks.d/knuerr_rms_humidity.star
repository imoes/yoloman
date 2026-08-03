def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.3711.15.1.1.1.2"
    name_oid = base_oid + ".2"
    reading_oid = base_oid + ".4"

    if params.get("_discover"):
        # PROBE: verify this is actually a Knürr RMS device via sysObjectID
        sysid_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid_res.rc != 0:
            return {"changed": False, "msg": "no snmp agent or not a knuerr device",
                    "data": {"discovery": []}}
        sysid_val = sysid_res.stdout.strip()
        # Expect ".1.3.6.1.4.1.3711.15.1" as a prefix
        if not sysid_val.startswith(".1.3.6.1.4.1.3711.15.1"):
            return {"changed": False, "msg": "not a knuerr RMS device",
                    "data": {"discovery": []}}

        # Fetch the humidity name (col .2) and reading (col .4) via snmpwalk -Oqn
        walk_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
            mutates=False,
        )
        if walk_res.rc != 0 or not walk_res.stdout.strip():
            return {"changed": False, "msg": "no humidity data on device",
                    "data": {"discovery": []}}

        metrics = ["humidity"]
        return {"changed": False,
                "msg": "discovered humidity sensor",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": (70, 75),
                                           "levels_lower": (40, 30)},
                     "metrics": metrics}]}}

    # CHECK MODE — single-service check (item "")
    # Re-confirm device identity (absence -> UNKNOWN, never OK)
    sysid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysid_res.rc != 0:
        return {"changed": False, "msg": "snmp unreachable or not a knuerr device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysid_val = sysid_res.stdout.strip()
    if not sysid_val.startswith(".1.3.6.1.4.1.3711.15.1"):
        return {"changed": False, "msg": "not a knuerr RMS device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch name and reading columns
    name_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, name_oid],
        mutates=False,
    )
    reading_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, reading_oid],
        mutates=False,
    )
    if name_res.rc != 0 or reading_res.rc != 0:
        return {"changed": False, "msg": "could not read humidity OIDs",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name_val = name_res.stdout.strip()
    reading_raw = reading_res.stdout.strip()
    # Strip any surrounding quotes type-tag handled by -Oqv
    if reading_raw.startswith('"') and reading_raw.endswith('"'):
        reading_raw = reading_raw[1:-1]

    if not reading_raw:
        return {"changed": False, "msg": "empty humidity reading",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Value is a plain integer (humidity * 10)
    reading_val = reading_raw
    # Remove possible INTEGER type remnants just in case
    if ":" in reading_val:
        reading_val = reading_val.split(":")[-1].strip()

    if not reading_val.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid humidity reading: %s" % reading_val,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    humidity = int(reading_val) / 10.0

    levels = params.get("levels", (70, 75))
    levels_lower = params.get("levels_lower", (40, 30))
    warn_u = levels[0] if len(levels) >= 1 else 70
    crit_u = levels[1] if len(levels) >= 2 else 75
    warn_l = levels_lower[0] if len(levels_lower) >= 1 else 40
    crit_l = levels_lower[1] if len(levels_lower) >= 2 else 30

    # check_humidity: lower levels warn/crit apply when value <= warn/crit
    # upper levels warn/crit apply when value >= warn/crit
    if humidity <= crit_l:
        state = "CRIT"
    elif humidity <= warn_l:
        state = "WARN"
    elif humidity >= crit_u:
        state = "CRIT"
    elif humidity >= warn_u:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "%s: %f%% humidity" % (name_val, humidity),
            "data": {"state": state,
                     "metrics": {"humidity": humidity},
                     "details": "Name: %s\nHumidity: %f%%" % (name_val, humidity)}}