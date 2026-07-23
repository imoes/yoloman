def main(ctx, params):
    # Discovery mode: yield one service item per host (single service, no items)
    if params.get("_discover"):
        # Probe SNMP section .1.3.6.1.4.1.12383.3.1.2.1 (operation_status) to detect presence
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.12383.3.1.2.1"
        ], mutates=False)
        # If we got any output, the section exists
        if res.rc == 0 and res.stdout.strip() != "":
            return {
                "changed": False,
                "msg": "discovered NTLS Links service",
                "data": {
                    "discovery": [
                        {"item": "", "params": {}, "metrics": ["connections"]}
                    ]
                }
            }
        return {
            "changed": False,
            "msg": "no NTLS data available",
            "data": {"discovery": []}
        }

    # Check mode for item "" (single-service check)
    # Fetch links OID: .1.3.6.1.4.1.12383.3.1.2.3.0
    links_oid = ".1.3.6.1.4.1.12383.3.1.2.3.0"
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), links_oid
    ], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "failed to retrieve links data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse snmpget output: "<oid> = INTEGER: <value>" or similar
    line = res.stdout.strip()
    parts = line.split(":")
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "unexpected snmpget output",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    value_str = parts[-1].strip()
    # Remove trailing spaces and any trailing whitespace
    value_str = value_str.rstrip()
    # Extract integer (strip trailing space, possible ' INTEGER:' prefix)
    value_str = value_str.split()[-1] if value_str.split() else value_str

    # Safely convert to int using guard instead of try/except
    links = int(value_str) if value_str.isdigit() else -1
    if links < 0:
        return {
            "changed": False,
            "msg": "cannot parse links value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Determine state based on thresholds (warn/crit levels)
    warn = params.get("levels", ("no_levels", None))
    crit = params.get("levels", ("no_levels", None))

    # Extract numeric levels if provided as tuple
    warn_val = None
    crit_val = None
    if type(warn) == "list" and len(warn) >= 2:
        if warn[0] == "levels":
            warn_val = warn[1]
        if len(warn) >= 3 and type(warn[2]) == "list":
            crit_val = warn[2][1] if len(warn[2]) >= 2 else None
    elif type(params.get("levels")) == "list":
        # Checkmk default: levels=("no_levels", None) -> no levels
        lvl = params.get("levels")
        if type(lvl) == "list" and len(lvl) >= 2:
            if lvl[0] != "no_levels":
                warn_val = lvl[1]
                if len(lvl) >= 3 and type(lvl[2]) == "list" and len(lvl[2]) >= 2:
                    crit_val = lvl[2][1]

    # Apply levels
    state = "OK"
    if warn_val != None and links >= warn_val:
        state = "WARN"
    if crit_val != None and links >= crit_val:
        state = "CRIT"

    # Build summary
    summary = "%d links" % links

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"connections": links},
            "details": ""
        }
    }