def main(ctx, params):
    # ===== Discovery mode: always yield one service for "System" =====
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "System",
                        "params": {"levels": (35.0, 40.0)},
                        "metrics": ["temp"]
                    }
                ]
            }
        }

    # ===== Check mode: get temperature via SNMP =====
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    oid = ".1.3.6.1.4.1.3652.3.1.1.6"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, oid
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse snmpwalk output: "OID = INTEGER: value"
    lines = res.stdout.strip().splitlines()
    if len(lines) == 0:
        return {
            "changed": False,
            "msg": "no SNMP data returned",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Look for first line and extract value (only one OID expected)
    value_str = ""
    for line in lines:
        if "=" in line:
            parts = line.split("=")
            if len(parts) >= 2:
                val_part = parts[1].strip()
                if val_part.startswith("INTEGER:"):
                    value_str = val_part.split(":", 1)[1].strip()
                    break
                elif val_part.isdigit():
                    value_str = val_part
                    break

    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "could not parse temperature value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    temp = int(value_str)

    # Apply thresholds from params (Checkmk defaults: levels=(35.0, 40.0))
    warn = 35.0
    crit = 40.0
    if params.get("levels") != None and type(params.get("levels")) == "list":
        levels = params.get("levels")
        if len(levels) >= 2:
            warn = float(levels[0])
            crit = float(levels[1])

    # Determine state
    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Temperature: %d C" % temp,
        "data": {
            "state": state,
            "metrics": {"temp": temp},
            "details": ""
        }
    }