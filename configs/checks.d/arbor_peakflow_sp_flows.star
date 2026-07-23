def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["flows"]
                    }
                ]
            }
        }

    # Single-service check: item is always ""
    res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.9694.1.4.2.1.12.0"], mutates=False)
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

    # Parse single value from snmpwalk output: "OID = INTEGER: value"
    value_str = ""
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(".1.3.6.1.4.1.9694.1.4.2.1.12.0"):
            parts = stripped.split("=")
            if len(parts) == 2:
                val_part = parts[1].strip()
                # Remove leading "INTEGER: " or just extract number
                if val_part.startswith("INTEGER: "):
                    value_str = val_part[9:].strip()
                else:
                    # Try to extract trailing number
                    for token in val_part.split():
                        if token.isdigit():
                            value_str = token
                            break
                break

    flows = int(value_str) if value_str.isdigit() else None

    if flows == None:
        return {
            "changed": False,
            "msg": "could not parse flow count",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Checkmk default levels are absent (no warn/crit), so only report raw value
    return {
        "changed": False,
        "msg": "Flows: %d" % flows,
        "data": {
            "state": "OK",
            "metrics": {"flows": flows},
            "details": ""
        }
    }
