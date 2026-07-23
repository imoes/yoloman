_BLADE_BX_STATUS = {
    "1": "unknown",
    "2": "sensor-disabled",
    "3": "ok",
    "4": "sensor-failed",
    "5": "warning-temp",
    "6": "critical-temp",
    "7": "not-available",
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.7244.1.1.1.3.4.1.1"
        ], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            # Parse "OID = TYPE: value" format
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            value_part = parts[1].strip()
            # Extract last field after colon (value)
            if ":" in value_part:
                value = value_part.rsplit(":", 1)[1].strip()
            else:
                continue
            
            # Split value into fields (status, descr, ...)
            fields = value.split()
            if len(fields) < 7:
                continue
            
            # Fields: index, status, descr, level_warn, level_crit, temp, crit_react
            status_str = fields[1]
            descr = fields[2]
            
            # Check if status is valid and not "not-available" (7)
            if status_str.isdigit():
                status = int(status_str)
                if status != 7:
                    items.append({
                        "item": descr,
                        "params": {},
                        "metrics": ["temp"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.7244.1.1.1.3.4.1.1"
    ], mutates=False)
    
    # Parse SNMP data
    found = False
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        if ":" in value_part:
            value = value_part.rsplit(":", 1)[1].strip()
        else:
            continue
        
        fields = value.split()
        if len(fields) < 7:
            continue
        
        # index, status, descr, level_warn, level_crit, temp, crit_react
        descr = fields[2]
        if descr != item:
            continue
        
        found = True
        
        status_str = fields[1]
        level_warn_str = fields[3]
        level_crit_str = fields[4]
        temp_str = fields[5]
        crit_react = fields[6]
        
        # Validate status field is numeric
        if not status_str.isdigit():
            return {
                "changed": False,
                "msg": "Device %s not found in SNMP data" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        status = int(status_str)
        level_warn = int(level_warn_str) if level_warn_str.isdigit() else 0
        level_crit = int(level_crit_str) if level_crit_str.isdigit() else 0
        temp = int(temp_str) if temp_str.isdigit() else 0
        
        # Check critical reaction flag (2 = active, non-2 = not present/poweroff)
        if crit_react != "2":
            return {
                "changed": False,
                "msg": "Temperature not present or poweroff",
                "data": {
                    "state": "CRIT",
                    "metrics": {"temp": float(temp)},
                    "details": ""
                }
            }
        
        # Check status
        if status != 3:
            status_msg = _BLADE_BX_STATUS.get(status_str, "unknown")
            return {
                "changed": False,
                "msg": "Status is %s" % status_msg,
                "data": {
                    "state": "CRIT",
                    "metrics": {"temp": float(temp)},
                    "details": ""
                }
            }
        
        # Apply temperature thresholds (warn/crit from params or defaults)
        warn = params.get("warn", 20.0)  # Checkmk default: 20°C warn
        crit = params.get("crit", 40.0)  # Checkmk default: 40°C crit
        
        # Check against device-provided thresholds (level_warn, level_crit)
        # If device has valid thresholds, use those; else use defaults
        dev_warn = level_warn if level_warn != 0 else warn
        dev_crit = level_crit if level_crit != 0 else crit
        
        # Determine state
        if temp >= dev_crit:
            state = "CRIT"
        elif temp >= dev_warn:
            state = "WARN"
        else:
            state = "OK"
        
        msg = "Temperature: %d C" % temp
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": state,
                "metrics": {"temp": float(temp)},
                "details": ""
            }
        }
    
    # Device not found in SNMP data
    if not found:
        return {
            "changed": False,
            "msg": "Device %s not found in SNMP data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
