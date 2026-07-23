def main(ctx, params):
    # SNMP base for CPS UPS battery: .1.3.6.1.4.1.3808.1.1.1.2.2
    # OIDs: 1=capacity (%), 3=temperature (Celsius), 4=battime (TimeTicks)
    base_oid = ".1.3.6.1.4.1.3808.1.1.1.2.2"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode
    if params.get("_discover"):
        # We discover both the battery capacity and temperature services
        # Since the check is per-host (not per-item), we emit single-service entries
        discovery = []

        # Battery capacity service
        discovery.append({
            "item": "",
            "params": {
                "capacity": (95, 90),
                "battime": (0, 0)
            },
            "metrics": ["battery_capacity", "battery_seconds_remaining"]
        })

        # Battery temperature service
        discovery.append({
            "item": "Battery",
            "params": {},
            "metrics": ["temp"]
        })

        return {
            "changed": False,
            "msg": "discovered 2 services",
            "data": {"discovery": discovery}
        }

    # Check mode
    item = params.get("item", "")
    # Run snmpwalk to fetch all battery-related OIDs
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1", base_oid + ".3", base_oid + ".4"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output into dict
    parsed = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        # Strip leading base to get OID tail
        tail = oid_part.replace(base_oid + ".", "")
        if tail == "1":  # capacity
            val = value_part.split(":")[-1].strip()
            if val and val.isdigit():
                parsed["capacity"] = int(val)
        elif tail == "3":  # temperature
            val = value_part.split(":")[-1].strip()
            if val and val.isdigit() and val != "NULL":
                parsed["temperature"] = int(val)
        elif tail == "4":  # battime (TimeTicks)
            val = value_part.split(":")[-1].strip()
            if val and val.isdigit():
                parsed["battime"] = float(val) / 100.0  # convert to seconds

    # Handle temperature check
    if item == "Battery":
        if "temperature" not in parsed:
            return {
                "changed": False,
                "msg": "no temperature data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }

        temp = parsed["temperature"]
        warn = params.get("levels_upper", (None, None))[0] if params.get("levels_upper") else None
        crit = params.get("levels_upper", (None, None))[1] if params.get("levels_upper") else None
        # Default to standard thresholds if none provided
        if not warn and not crit:
            warn = 30
            crit = 40

        state = "OK"
        details_parts = []

        if crit != None and temp >= crit:
            state = "CRIT"
            details_parts.append("Crit: %d C" % crit)
        elif warn != None and temp >= warn:
            state = "WARN"
            details_parts.append("Warn: %d C" % warn)

        details = " ".join(details_parts) if details_parts else ""
        return {
            "changed": False,
            "msg": "Temperature: %d C" % temp,
            "data": {
                "state": state,
                "metrics": {"temp": temp},
                "details": details
            }
        }

    # Battery capacity check (item == "")
    if "capacity" not in parsed:
        return {
            "changed": False,
            "msg": "no battery data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    capacity = parsed["capacity"]
    battime = parsed.get("battime")

    # Capacity thresholds (lower levels)
    capacity_levels = params.get("capacity", (95, 90))
    capacity_warn = capacity_levels[0]
    capacity_crit = capacity_levels[1]

    # Check capacity against lower levels
    if capacity <= capacity_crit:
        state = "CRIT"
    elif capacity <= capacity_warn:
        state = "WARN"
    else:
        state = "OK"

    details_parts = []
    if state != "OK":
        details_parts.append("(warn/crit at %d/%d%%)" % (capacity_warn, capacity_crit))

    msg = "Capacity at %d%%" % capacity
    if details_parts:
        msg += " " + " ".join(details_parts)

    metrics = {"battery_capacity": capacity}

    # Add remaining time if available
    if battime != None:
        minutes_left = battime / 60.0
        battime_levels = params.get("battime", (0, 0))
        if battime_levels and (battime_levels[0] > 0 or battime_levels[1] > 0):
            warn_mins, crit_mins = battime_levels
            if minutes_left <= crit_mins:
                state = "CRIT"
            elif minutes_left <= warn_mins:
                state = "WARN"

            metrics["battery_seconds_remaining"] = battime

        msg += ", %f minutes remaining on battery" % minutes_left

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }