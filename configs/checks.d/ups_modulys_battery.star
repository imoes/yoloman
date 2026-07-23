# Module: ups_modulys_battery.star
# Read-only check for battery charge status via SNMP

# Constants
DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_VALUE = ".1.3.6.1.4.1.2254.2.4"
SNMP_BASE = ".1.3.6.1.4.1.2254.2.4.7"
OID_HEALTH = "1"
OID_UPTIME = "4"
OID_REMAINING_TIME = "5"
OID_CAPACITY = "8"
OID_TEMPERATURE = "9"

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: check if device is present and yields battery data
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On", params.get("host", "localhost"), DETECT_OID], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Check device OID match for Modulys UPS detection
        found = False
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith(DETECT_OID + " = "):
                val = stripped[(len(DETECT_OID) + 3):].strip()
                if val == DETECT_VALUE:
                    found = True
                    break
        
        if not found:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Device detected - check battery section is available
        bat_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On", params.get("host", "localhost"), SNMP_BASE + "." + OID_UPTIME], mutates=False)
        if bat_res.rc != 0 or not bat_res.stdout or not bat_res.stdout.strip().endswith(" = INTEGER:"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Extract uptime value
        uptime_line = bat_res.stdout.strip()
        idx = uptime_line.rfind(" = INTEGER: ")
        if idx == -1:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        uptime_val = uptime_line[idx + len(" = INTEGER: "):].strip()
        if not uptime_val.isdigit() or int(uptime_val) < 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Single-service check - always return one item
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "capacity": [95, 90],
                            "battime": [0, 0]
                        },
                        "metrics": ["capacity", "uptime", "remaining_time", "health", "temperature"]
                    }
                ]
            }
        }

    # Check mode for item ""
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "no such item",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Collect all battery SNMP data
    bat_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On", params.get("host", "localhost"),
        SNMP_BASE + "." + OID_HEALTH,
        SNMP_BASE + "." + OID_UPTIME,
        SNMP_BASE + "." + OID_REMAINING_TIME,
        SNMP_BASE + "." + OID_CAPACITY,
        SNMP_BASE + "." + OID_TEMPERATURE
    ], mutates=False)
    
    if bat_res.rc != 0 or not bat_res.stdout:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse SNMP output into dict by OID suffix
    data_map = {}
    for line in bat_res.stdout.splitlines():
        stripped = line.strip()
        eq_idx = stripped.find(" = ")
        if eq_idx == -1:
            continue
        oid_part = stripped[:eq_idx].strip()
        val_part = stripped[eq_idx + 3:].strip()
        
        # Extract numeric OID suffix (e.g., "1.3.6.1.4.1.2254.2.4.7.4" -> "4")
        suffix = oid_part.rsplit(".", 1)[-1]
        data_map[suffix] = val_part
    
    # Extract values with defaults
    uptime_str = data_map.get(OID_UPTIME, "")
    if uptime_str == "":
        return {
            "changed": False,
            "msg": "missing uptime data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    uptime = int(uptime_str) if uptime_str.isdigit() else 0
    
    health_str = data_map.get(OID_HEALTH, "")
    health = int(health_str) if health_str.isdigit() else -1
    
    remaining_str = data_map.get(OID_REMAINING_TIME, "")
    if uptime == 0 or remaining_str == "" or remaining_str == "0":
        remaining_time = float(2147483647)  # sys.maxsize in Python 3
    else:
        remaining_time = float(remaining_str) if remaining_str.replace('.','').replace('-','').isdigit() else 2147483647
    
    capacity_str = data_map.get(OID_CAPACITY, "")
    capacity = int(capacity_str) if capacity_str.isdigit() else 0
    
    temp_str = data_map.get(OID_TEMPERATURE, "")
    temperature = float(temp_str) if temp_str.replace('.','').replace('-','').isdigit() else None
    
    # Determine state and messages
    msg_parts = []
    
    # Uptime check
    if uptime == 0:
        msg_parts.append("On mains")
        state = "OK"
    else:
        minutes = uptime // 60
        msg_parts.append("Discharging for %d minutes" % minutes)
        state = "OK"
    
    # Health check
    if health == 1:
        msg_parts.append("Battery health weak")
        if state == "OK":
            state = "WARN"
    elif health == 2:
        msg_parts.append("Battery needs to be replaced")
        state = "CRIT"
    
    # Remaining time check (lower levels)
    battime = params.get("battime", [0, 0])
    if battime != None and type(battime) == "list" and len(battime) >= 2:
        warn_time = float(battime[0])
        crit_time = float(battime[1])
        if crit_time > 0 and remaining_time <= crit_time:
            state = "CRIT"
            msg_parts.append("Minutes remaining: %d" % int(remaining_time))
        elif warn_time > 0 and remaining_time <= warn_time:
            if state != "CRIT":
                state = "WARN"
            msg_parts.append("Minutes remaining: %d" % int(remaining_time))
        else:
            msg_parts.append("Minutes remaining: %d" % int(remaining_time))
    else:
        msg_parts.append("Minutes remaining: %d" % int(remaining_time))
    
    # Capacity check (lower levels)
    capacity_params = params.get("capacity", [95, 90])
    if capacity_params != None and type(capacity_params) == "list" and len(capacity_params) >= 2:
        warn_cap = float(capacity_params[0])
        crit_cap = float(capacity_params[1])
        if crit_cap > 0 and capacity <= crit_cap:
            state = "CRIT"
            msg_parts.append("Battery capacity at %d%%" % capacity)
        elif warn_cap > 0 and capacity <= warn_cap:
            if state != "CRIT":
                state = "WARN"
            msg_parts.append("Battery capacity at %d%%" % capacity)
        else:
            msg_parts.append("Battery capacity at %d%%" % capacity)
    else:
        msg_parts.append("Battery capacity at %d%%" % capacity)
    
    # Temperature check (only if present)
    if temperature != None:
        temp_params = params.get("temp", {})
        warn_temp = temp_params.get("levels", (None, None))
        if type(warn_temp) == "list" and len(warn_temp) >= 2:
            warn_val = warn_temp[0]
            crit_val = warn_temp[1]
            if crit_val != None and temperature >= crit_val:
                state = "CRIT"
                msg_parts.append("Temperature: %d C" % int(temperature))
            elif warn_val != None and temperature >= warn_val:
                if state != "CRIT":
                    state = "WARN"
                msg_parts.append("Temperature: %d C" % int(temperature))
            else:
                msg_parts.append("Temperature: %d C" % int(temperature))
        else:
            msg_parts.append("Temperature: %d C" % int(temperature))
    
    # Build metrics dict (only numeric values)
    metrics = {
        "uptime": uptime,
        "capacity": capacity,
        "remaining_time": remaining_time,
        "health": health
    }
    if temperature != None:
        metrics["temperature"] = temperature
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }