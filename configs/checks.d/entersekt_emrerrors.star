def main(ctx, params):
    # Discovery mode: single-service check, one entry with empty item
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": [100, 200]},
                        "metrics": ["Errors"],
                    }
                ]
            },
        }

    # Check mode: probe SNMP for Entersekt EMR errors (OID .1.3.6.1.4.1.38235.2.3.4.0)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c",
            community,
            "-On",
            host,
            ".1.3.6.1.4.1.38235.2.3.4.0",
        ],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP fetch failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse snmpget output: "<oid> = INTEGER: <value>"
    line = res.stdout.strip()
    if line == "" or line.find(":") == -1:
        return {
            "changed": False,
            "msg": "unexpected SNMP output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    parts = line.split(":", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "cannot parse SNMP value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    val_str = parts[1].strip()
    if not val_str.isdigit():
        return {
            "changed": False,
            "msg": "SNMP value is not an integer",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    errors = int(val_str)

    # Thresholds
    levels = params.get("levels", [100, 200])
    warn = levels[0]
    crit = levels[1]

    # Determine state
    if errors >= crit:
        state = "CRIT"
        summary = "Number of errors is %d which is higher than %d" % (errors, crit)
    elif errors >= warn:
        state = "WARN"
        summary = "Number of errors is %d which is higher than %d" % (errors, warn)
    else:
        state = "OK"
        summary = "Number of errors is %d" % errors

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"Errors": errors},
            "details": "",
        },
    }
