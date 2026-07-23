# Module-level constants
DEFAULT_LEVELS_LOWER = (0.5, 0.0)
BASE_OID = ".1.3.6.1.4.1.12124.2.55.1"
OID_NAME = BASE_OID + ".3"
OID_VOLTAGE = BASE_OID + ".4"

def _isilon_power_item_name(sensor_name):
    return sensor_name.replace("Voltage", "").replace("  ", " ").strip()

def _get_oid_values(ctx, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", ctx.get("community", "public"), 
                   "-On", ctx.get("host", "localhost"), base_oid], 
                  mutates=False)
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)
    
    values = []
    lines = res.stdout.splitlines()
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(base_oid):
            parts = stripped.split(" = ", 1)
            if len(parts) == 2:
                value = parts[1].strip().strip('"')
                values.append(value)
    return values

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Fetch all sensor names and voltages
        names = _get_oid_values(ctx, OID_NAME)
        voltages = _get_oid_values(ctx, OID_VOLTAGE)
        
        # Only keep power supply sensors
        items = []
        for i in range(len(names)):
            name = names[i]
            if "Power Supply" in name or "PS" in name:
                item_name = _isilon_power_item_name(name)
                items.append({
                    "item": item_name,
                    "params": {"levels_lower": DEFAULT_LEVELS_LOWER},
                    "metrics": ["voltage"]
                })
        
        return {"changed": False, "msg": "discovered %d power sensors" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    
    # Fetch sensor data
    names = _get_oid_values(ctx, OID_NAME)
    voltages = _get_oid_values(ctx, OID_VOLTAGE)
    
    # Find matching item
    found = False
    for i in range(len(names)):
        name = names[i]
        if item == _isilon_power_item_name(name):
            if i >= len(voltages):
                return {"changed": False, "msg": "voltage data missing for item",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            
            voltage_str = voltages[i]
            volt = 0.0
            if voltage_str.isdigit() or (voltage_str.replace(".", "", 1).isdigit() and voltage_str.count(".") <= 1):
                volt = float(voltage_str)
            else:
                return {"changed": False, "msg": "invalid voltage value for %s" % item,
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            
            found = True
            # Get thresholds
            levels_lower = params.get("levels_lower", DEFAULT_LEVELS_LOWER)
            warn_lower = levels_lower[0]
            crit_lower = levels_lower[1]
            
            levels_upper = params.get("levels_upper", (None, None))
            warn_upper = levels_upper[0]
            crit_upper = levels_upper[1]
            
            # Determine state and build message
            infotext = "%f V" % volt
            state = "OK"
            
            # Check lower thresholds first
            if volt < crit_lower:
                state = "CRIT"
                infotext = infotext + " (warn/crit below %f/%f V)" % (warn_lower, crit_lower)
            elif volt < warn_lower:
                state = "WARN"
                infotext = infotext + " (warn/crit below %f/%f V)" % (warn_lower, crit_lower)
            
            # Then check upper thresholds if defined
            if warn_upper != None:
                if volt >= crit_upper:
                    state = "CRIT"
                    infotext = infotext + " (warn/crit at or above %f/%f V)" % (warn_upper, crit_upper)
                elif volt >= warn_upper:
                    state = "WARN"
                    infotext = infotext + " (warn/crit at or above %f/%f V)" % (warn_upper, crit_upper)
            
            return {"changed": False, "msg": infotext,
                    "data": {"state": state, "metrics": {"voltage": volt}, "details": ""}}
    
    # Item not found
    if not found:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
