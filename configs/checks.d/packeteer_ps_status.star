def main(ctx, params):
    # Discovery mode: one service per device with any PS entries
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Check mode: probe SNMP for power supply statuses
    # The check queries .1.3.6.1.4.1.2334.2.1.5.8 and .10
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.2334.2.1.5.8", ".1.3.6.1.4.1.2334.2.1.5.10"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed: " + (res.stderr if res.stderr else str(res.rc)),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse the SNMP output: each OID line yields a value
    lines = res.stdout.splitlines()
    statuses = []
    for line in lines:
        # Format: OID = INTEGER: value or OID = value
        # We only need the numeric value (1 = okay, 2 = not okay)
        parts = line.strip().split()
        if len(parts) >= 3 and parts[1] == "=":
            val_str = parts[-1].lstrip("INTEGER:").strip()
            if val_str.isdigit():
                statuses.append(val_str)

    # If no data, report UNKNOWN
    if not statuses:
        return {
            "changed": False,
            "msg": "no power supply data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Check each power supply
    failures = []
    for nr, status in enumerate(statuses):
        if status == "1":
            # okay - no action
            pass
        else:
            failures.append("Power Supply " + str(nr) + " not okay")

    # Determine state
    if not failures:
        state = "OK"
        summary = "all power supplies okay"
    else:
        state = "CRIT"
        summary = ", ".join(failures)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
