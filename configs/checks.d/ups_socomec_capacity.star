def main(ctx, params):
    # Discovery mode: single-service check, item is always ""
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"battime": (0, 0), "capacity": (95, 90)},
                                   "metrics": ["capacity", "percent"]}]}
        }

    # Check mode
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "unexpected item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch SNMP data: .1.3.6.1.4.1.4555.1.1.1.1.2.{2,3,4}
    # OIDs for: upsSecondsOnBattery, upsEstimatedMinutesRemaining, upsEstimatedChargeRemaining
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.4555.1.1.1.1.2.2",
        ".1.3.6.1.4.1.4555.1.1.1.1.2.3",
        ".1.3.6.1.4.1.4555.1.1.1.1.2.4"
    ], mutates=False)

    lines = res.stdout.splitlines()
    if len(lines) < 3:
        return {
            "changed": False,
            "msg": "SNMP output incomplete",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse values: expected format "OID = INTEGER: <value>"
    time_on_bat = -1
    minutes_left = -1
    percent_fuel = -1

    for line in lines:
        stripped = line.strip()
        if stripped.find("INTEGER: ") != -1:
            parts = stripped.rsplit(" ", 1)
            if len(parts) == 2:
                val_str = parts[1]
                if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                    val = int(val_str)
                    # Determine which OID by OID prefix matching
                    if stripped.find(".1.3.6.1.4.1.4555.1.1.1.1.2.2 ") != -1:
                        time_on_bat = val
                    elif stripped.find(".1.3.6.1.4.1.4555.1.1.1.1.2.3 ") != -1:
                        minutes_left = val
                    elif stripped.find(".1.3.6.1.4.1.4555.1.1.1.1.2.4 ") != -1:
                        percent_fuel = val

    # Apply defaults (same as Checkmk)
    battime_warn, battime_crit = params.get("battime", (0, 0))
    cap_warn, cap_crit = params.get("capacity", (95, 90))

    # Determine state and build message
    state = "OK"
    summary_parts = []

    # Check time left on battery
    if minutes_left != -1:
        if minutes_left <= battime_crit:
            state = "CRIT"
            summary_parts.append("%d min left on battery (crit at %d min)" % (minutes_left, battime_crit))
        elif minutes_left < battime_warn:
            state = "WARN"
            summary_parts.append("%d min left on battery (warn at %d min)" % (minutes_left, battime_warn))
        else:
            summary_parts.append("%d min left on battery" % minutes_left)

    # Check percentual capacity
    if percent_fuel != -1:
        if percent_fuel <= cap_crit:
            state = "CRIT"
            summary_parts.append("capacity: %d%% (crit at %d%%)" % (percent_fuel, cap_crit))
        elif percent_fuel < cap_warn:
            state = "WARN"
            summary_parts.append("capacity: %d%% (warn at %d%%)" % (percent_fuel, cap_warn))
        else:
            summary_parts.append("capacity: %d%%" % percent_fuel)

    # Output time on battery if > 0
    if time_on_bat > 0:
        summary_parts.append("On battery for %d min" % time_on_bat)

    # Build final summary
    summary = ", ".join(summary_parts)

    # Build metrics dict
    metrics = {}
    if minutes_left != -1:
        metrics["capacity"] = float(minutes_left)
    if percent_fuel != -1:
        metrics["percent"] = float(percent_fuel)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }