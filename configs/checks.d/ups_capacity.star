# ===== checkmk.ups_capacity Starlark translation =====

# SNMP OIDs for ups_battery_capacity section
OID_SECONDS_LEFT = ".1.3.6.1.2.1.33.1.2.3.0"  # Remaining battery backup time [min]
OID_PERCENT_CHARGED = ".1.3.6.1.2.1.33.1.2.4.0"  # Battery charge level [%]

# SNMP OIDs for ups_on_battery and ups_seconds_on_battery sections
OID_SECONDS_ON_BATTERY = ".1.3.6.1.2.1.33.1.2.2.0"  # Seconds on battery [sec]

# Default thresholds from CHECK_DEFAULT_PARAMETERS
DEFAULT_CAPACITY_WARN = 95
DEFAULT_CAPACITY_CRIT = 90
DEFAULT_BATTIME_WARN = 0
DEFAULT_BATTIME_CRIT = 0

def _snmp_get(ctx, host, community, oid):
    """Fetch single OID value via SNMP, return None if missing or invalid."""
    res = ctx.run([
        "snmpget", "-v2c", "-c", community,
        host, oid
    ], mutates=False)
    if res.rc != 0:
        return None
    # Parse line like: .1.3.6.1.2.1.33.1.2.3.0 = INTEGER: 45
    line = res.stdout.strip()
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return None
    value_part = parts[1].strip()
    if value_part.startswith("INTEGER:"):
        val = value_part[8:].strip()
        if val.isdigit():
            return int(val)
    elif value_part.isdigit():
        return int(value_part)
    return None

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    if params.get("_discover"):
        # Discovery: single service for "Battery capacity"
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "capacity": (DEFAULT_CAPACITY_WARN, DEFAULT_CAPACITY_CRIT),
                            "battime": (DEFAULT_BATTIME_WARN, DEFAULT_BATTIME_CRIT)
                        },
                        "metrics": ["battery_capacity", "battery_seconds_remaining"]
                    }
                ]
            }
        }
    
    # ===== check mode =====
    item = params.get("item", "")
    # Only handle the expected item
    if item != "":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Gather data via SNMP
    seconds_left_min = _snmp_get(ctx, host, community, OID_SECONDS_LEFT)
    percent_charged = _snmp_get(ctx, host, community, OID_PERCENT_CHARGED)
    seconds_on_bat = _snmp_get(ctx, host, community, OID_SECONDS_ON_BATTERY)
    
    # Convert seconds_left from minutes to seconds
    seconds_left_sec = seconds_left_min * 60 if seconds_left_min != None else None
    
    # Determine if on battery
    on_battery = False
    if seconds_on_bat != None and seconds_on_bat > 0:
        on_battery = True
    elif seconds_left_min != None and seconds_left_min > 0:
        on_battery = True
    
    # Thresholds from params
    capacity_levels = params.get("capacity", (DEFAULT_CAPACITY_WARN, DEFAULT_CAPACITY_CRIT))
    battime_levels = params.get("battime", (DEFAULT_BATTIME_WARN, DEFAULT_BATTIME_CRIT))
    warn_capacity = capacity_levels[0]
    crit_capacity = capacity_levels[1]
    warn_battime = battime_levels[0] * 60  # convert minutes to seconds
    crit_battime = battime_levels[1] * 60  # convert minutes to seconds
    
    # Evaluate battery capacity
    state = "OK"
    msg_parts = []
    metrics = {}
    
    # Capacity check
    if percent_charged == None:
        state = "UNKNOWN"
        msg_parts.append("Battery capacity not available")
    else:
        metrics["battery_capacity"] = float(percent_charged)
        # Check levels: lower thresholds for capacity (OK if >= warn/crit)
        if percent_charged <= crit_capacity:
            state = "CRIT"
        elif percent_charged <= warn_capacity:
            state = "WARN"
        msg_parts.append("Capacity: %d%%" % percent_charged)
    
    # Time remaining check
    if seconds_left_sec != None:
        metrics["battery_seconds_remaining"] = float(seconds_left_sec)
        # Only check when on battery (per Checkmk logic)
        if on_battery and seconds_left_sec > 0:
            if seconds_left_sec <= crit_battime:
                state = "CRIT"
            elif seconds_left_sec <= warn_battime:
                state = "WARN"
            msg_parts.append("Time remaining: %d s" % seconds_left_sec)
    
    # Time on battery info
    if seconds_on_bat != None and seconds_on_bat > 0:
        msg_parts.append("Time on battery: %d s" % seconds_on_bat)
    else:
        msg_parts.append("On mains")
    
    # Return result
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }