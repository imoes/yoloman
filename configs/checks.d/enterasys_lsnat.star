def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"current_bindings": None},
                        "metrics": ["current_bindings"]
                    }
                ]
            }
        }

    # Read SNMP data
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.5624.1.2.74.1.1.5.0"
    ], mutates=False)

    if res.rc != 0 or res.stdout == None or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse single OID value: format "OID = INTEGER: <value>"
    lines = res.stdout.splitlines()
    if len(lines) < 1:
        return {
            "changed": False,
            "msg": "no data returned",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    line = lines[0].strip()
    # Extract value after ": " or "="
    value_str = ""
    if line.find(": ") != -1:
        value_str = line.split(": ")[-1]
    elif line.find("=") != -1:
        value_str = line.split("=")[-1].strip()
    else:
        return {
            "changed": False,
            "msg": "cannot parse value from output",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Safely convert to integer (mimicking _saveint) - no try/except
    bindings = 0
    if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
        bindings = int(value_str)

    # Apply thresholds
    raw_levels = params.get("current_bindings")
    warn = None
    crit = None
    if raw_levels != None:
        if type(raw_levels) == "list" and len(raw_levels) >= 2:
            warn = int(raw_levels[0])
            crit = int(raw_levels[1])
        elif type(raw_levels) == "list" and len(raw_levels) == 1:
            warn = int(raw_levels[0])
            crit = warn
        else:
            warn = int(raw_levels)
            crit = warn

    # Determine state
    state = "OK"
    if warn != None and crit != None:
        if bindings >= crit:
            state = "CRIT"
        elif bindings >= warn:
            state = "WARN"
    elif warn != None and crit == None:
        if bindings >= warn:
            state = "WARN"

    msg = "Current bindings: %d" % bindings
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"current_bindings": bindings},
            "details": ""
        }
    }
