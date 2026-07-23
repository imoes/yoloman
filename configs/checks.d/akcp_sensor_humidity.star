# Constants defined at module top level
AKCP_HUMIDITY_CHECK_DEFAULT_PARAMETERS = {
    "levels": (60.0, 65.0),
    "levels_lower": (30.0, 35.0),
}

akcp_sensor_level_states = {
    "1": (2, "no status"),
    "2": (0, "normal"),
    "3": (1, "high warning"),
    "4": (2, "high critical"),
    "5": (1, "low warning"),
    "6": (2, "low critical"),
    "7": (2, "sensor error"),
}


def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Try primary OID tree first (akcp_sensor_humidity)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.3854.1.2.2.1.17.1"
        ], mutates=False)
        
        # Parse SNMP output - format: "OID = STRING: value" or "OID = INTEGER: value"
        entries = {}
        current_oid_base = ""
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_full = parts[0].strip()
            value = parts[1].strip()
            
            # Extract last OID component to determine field type
            oid_parts = oid_full.split(".")
            if len(oid_parts) > 0:
                last_oid = oid_parts[-1]
                if last_oid == "1":
                    # Description
                    entries[current_oid_base + ".1"] = value.strip('"')
                elif last_oid == "3":
                    # Percent (HumidityPercent)
                    current_oid_base = ".".join(oid_parts[:-1])
                    entries[current_oid_base + ".3"] = value
                elif last_oid == "4":
                    # Status
                    entries[current_oid_base + ".4"] = value
                elif last_oid == "5":
                    # Online (1: online, 2: offline)
                    entries[current_oid_base + ".5"] = value
        
        # Group by base OID
        items = []
        seen_bases = set()
        for oid, value in entries.items():
            if oid.endswith(".1"):  # description OID
                base = ".".join(oid.split(".")[:-1])
                if base in seen_bases:
                    continue
                seen_bases.add(base)
                
                # Get associated values
                desc = entries.get(base + ".1", "")
                percent = entries.get(base + ".3", "0")
                status = entries.get(base + ".4", "1")
                online = entries.get(base + ".5", "2")
                
                # Only include if online (status "1")
                if online == "1":
                    items.append({
                        "item": desc,
                        "params": {
                            "levels": AKCP_HUMIDITY_CHECK_DEFAULT_PARAMETERS.get("levels", (60.0, 65.0)),
                            "levels_lower": AKCP_HUMIDITY_CHECK_DEFAULT_PARAMETERS.get("levels_lower", (30.0, 35.0))
                        },
                        "metrics": ["humidity"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # CHECK MODE
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch humidity data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.3854.1.2.2.1.17.1"
    ], mutates=False)
    
    # Parse SNMP output into structured data
    section = []
    current_oid_base = ""
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_full = parts[0].strip()
        value = parts[1].strip()
        
        # Extract last OID component to determine field type
        oid_parts = oid_full.split(".")
        if len(oid_parts) > 0:
            last_oid = oid_parts[-1]
            if last_oid == "1":
                # Description
                current_oid_base = ".".join(oid_parts[:-1])
                description = value.strip('"')
            elif last_oid == "3":
                # Percent (HumidityPercent)
                percent = value
            elif last_oid == "4":
                # Status
                status = value
            elif last_oid == "5":
                # Online (1: online, 2: offline)
                online = value
                # Add complete record
                section.append([description, percent, status, online])
    
    # Find matching item
    found = False
    for description, percent, status, online in section:
        if description == item:
            found = True
            
            # Check online status
            if online != "1":
                return {
                    "changed": False,
                    "msg": "sensor is offline",
                    "data": {
                        "state": "CRIT",
                        "metrics": {"humidity": 0},
                        "details": "sensor is offline"
                    }
                }
            
            # Check sensor status
            if status in ["1", "7"]:
                state, state_name = akcp_sensor_level_states[status]
                return {
                    "changed": False,
                    "msg": "State: %s" % state_name,
                    "data": {
                        "state": "CRIT" if state == 2 else ("WARN" if state == 1 else "OK"),
                        "metrics": {"humidity": 0},
                        "details": "State: %s" % state_name
                    }
                }
            
            # Check humidity level
            humidity = 0
            if percent:
                if percent.isdigit():
                    humidity = int(percent)
                else:
                    # Guard against non-digit strings
                    if percent.find("-") == 0:
                        humidity = int(float(percent)) if percent.replace("-", "", 1).replace(".", "", 1).isdigit() else 0
                    else:
                        humidity = int(float(percent)) if percent.replace(".", "", 1).isdigit() else 0
            
            # Get thresholds from params
            levels = params.get("levels", AKCP_HUMIDITY_CHECK_DEFAULT_PARAMETERS.get("levels", (60.0, 65.0)))
            levels_lower = params.get("levels_lower", AKCP_HUMIDITY_CHECK_DEFAULT_PARAMETERS.get("levels_lower", (30.0, 35.0)))
            
            warn_high = float(levels[0])
            crit_high = float(levels[1])
            warn_low = float(levels_lower[0])
            crit_low = float(levels_lower[1])
            
            # Determine state
            state = "OK"
            msg_parts = []
            
            # High thresholds
            if humidity >= crit_high:
                state = "CRIT"
                msg_parts.append("CRIT: %d%%" % humidity)
            elif humidity >= warn_high:
                state = "WARN"
                msg_parts.append("WARN: %d%%" % humidity)
            
            # Low thresholds
            if humidity <= crit_low:
                state = "CRIT"
                msg_parts.append("CRIT: %d%%" % humidity)
            elif humidity <= warn_low:
                state = "WARN"
                msg_parts.append("WARN: %d%%" % humidity)
            
            if not msg_parts:
                msg_parts.append("%d%%" % humidity)
            
            return {
                "changed": False,
                "msg": "Humidity: " + ", ".join(msg_parts),
                "data": {
                    "state": state,
                    "metrics": {"humidity": humidity},
                    "details": "Humidity: %d%%" % humidity
                }
            }
    
    # Item not found
    if not found:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {"humidity": 0},
                "details": "sensor not found: " + item
            }
        }
