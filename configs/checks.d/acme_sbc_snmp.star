def main(ctx, params):
    if params.get("_discover"):
        # Discovery: ACME SBC health is a single-service check (item "")
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"lower_levels": ("fixed", (75, 50))},
                        "metrics": ["health_state"]
                    }
                ]
            }
        }

    # Check mode: single service, item is ""
    # Fetch health score and status via SNMP
    # OID base: .1.3.6.1.4.1.9148.3.2.1.1
    # oid 3: apSysHealthScore (integer)
    # oid 4: apSysRedundancy (string)
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.9148.3.2.1.1.3",
        ".1.3.6.1.4.1.9148.3.2.1.1.4"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    lines = res.stdout.strip().split("\n")
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "incomplete SNMP response",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse outputs:
    # Expected format: <oid>.<suffix> = INTEGER: <value> or STRING: "<value>"
    score_str = ""
    status_str = ""
    for line in lines:
        line = line.strip()
        if ".1.3.6.1.4.1.9148.3.2.1.1.3" in line:
            # INTEGER: <value>
            idx = line.find("=")
            if idx >= 0:
                val = line[idx+1:].strip()
                if val.startswith("INTEGER:"):
                    score_str = val.split(":", 1)[1].strip()
                else:
                    score_str = val
        elif ".1.3.6.1.4.1.9148.3.2.1.1.4" in line:
            # STRING: "<value>"
            idx = line.find("=")
            if idx >= 0:
                val = line[idx+1:].strip()
                if val.startswith("STRING:"):
                    # strip quotes
                    quoted = val.split(":", 1)[1].strip()
                    if quoted.startswith('"') and quoted.endswith('"'):
                        status_str = quoted[1:-1]
                    else:
                        status_str = quoted

    # Handle missing or invalid values
    if not score_str.isdigit():
        return {
            "changed": False,
            "msg": "health score not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    health_score = int(score_str)
    
    # Map status string to state
    map_states = {
        "0": ("unknown", 3),
        "1": ("initial", 1),
        "2": ("active", 0),
        "3": ("standby", 0),
        "4": ("out of service", 2),
        "5": ("unassigned", 2),
        "6": ("active (pending)", 1),
        "7": ("standby (pending)", 1),
        "8": ("out of service (pending)", 1),
        "9": ("recovery", 1)
    }

    status_map = map_states.get(status_str, ("unknown", 3))
    status_desc, state_idx = status_map

    # Check levels: lower_levels = ("fixed", (warn, crit))
    lower_levels = params.get("lower_levels", ("fixed", (75, 50)))
    if type(lower_levels) == "list" and len(lower_levels) == 2:
        # handle ("fixed", (75, 50)) pattern
        warn, crit = lower_levels[1]
    else:
        warn, crit = 75, 50

    # Determine state from health state (status) first
    state = "CRIT" if state_idx == 2 else ("WARN" if state_idx == 1 else "OK")
    if state == "OK" and health_score < crit:
        state = "CRIT"
    elif state == "OK" and health_score < warn:
        state = "WARN"

    # Build message
    msg = "Health state: %s, Score: %d%%" % (status_desc, health_score)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"health_state": health_score},
            "details": ""
        }
    }
