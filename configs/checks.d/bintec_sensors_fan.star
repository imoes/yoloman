# Module-level constants
FAN_SENSOR_TYPE = "2"

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.272.4.17.7.1.1.1"
        ], mutates=False)
        
        # Parse snmpwalk output: "<OID> = <TYPE>: <value>"
        lines = res.stdout.splitlines() if res.stdout else []
        section = []
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if not line:
                i += 1
                continue
            
            # Each entry has 5 fields: .1.3.6.1.4.1.272.4.17.7.1.1.1.2 = STRING: "value"
            # We need to group 5 consecutive lines for one sensor
            entry_values = []
            for j in range(5):
                if i + j >= len(lines):
                    break
                entry_line = lines[i + j].strip()
                # Extract value part after ": "
                colon_pos = entry_line.rfind(": ")
                if colon_pos == -1:
                    continue
                value_part = entry_line[colon_pos + 2:].strip()
                # Remove quotes if present
                if value_part.startswith('"') and value_part.endswith('"'):
                    value_part = value_part[1:-1]
                entry_values.append(value_part)
            
            if len(entry_values) == 5:
                section.append(entry_values)
                i += 5
            else:
                i += 1
        
        # Discover fans (sensor_type == "2")
        out = []
        for entry in section:
            if len(entry) < 5:
                continue
            sensor_type = entry[2] if len(entry) > 2 else ""
            sensor_descr = entry[1] if len(entry) > 1 else ""
            if sensor_type == FAN_SENSOR_TYPE and sensor_descr:
                out.append({
                    "item": sensor_descr,
                    "params": {"lower": (2000, 1000)},
                    "metrics": ["rpm"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.272.4.17.7.1.1.1"
    ], mutates=False)
    
    lines = res.stdout.splitlines() if res.stdout else []
    section = []
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        
        entry_values = []
        for j in range(5):
            if i + j >= len(lines):
                break
            entry_line = lines[i + j].strip()
            colon_pos = entry_line.rfind(": ")
            if colon_pos == -1:
                continue
            value_part = entry_line[colon_pos + 2:].strip()
            if value_part.startswith('"') and value_part.endswith('"'):
                value_part = value_part[1:-1]
            entry_values.append(value_part)
        
        if len(entry_values) == 5:
            section.append(entry_values)
            i += 5
        else:
            i += 1
    
    # Find the requested fan
    for entry in section:
        if len(entry) < 5:
            continue
        sensor_descr = entry[1] if len(entry) > 1 else ""
        sensor_value = entry[3] if len(entry) > 3 else ""
        
        if sensor_descr == item:
            # Parse rpm value - guard before conversion
            if not sensor_value or not sensor_value.isdigit():
                rpm = 0
            else:
                rpm = int(sensor_value)
            
            # Get thresholds from params
            lower_warn, lower_crit = params.get("lower", (2000, 1000))
            
            # Determine state: lower levels -> WARN if <= warn, CRIT if <= crit
            if rpm <= lower_crit:
                state = "CRIT"
            elif rpm <= lower_warn:
                state = "WARN"
            else:
                state = "OK"
            
            msg = "%s at %d RPM" % (item, rpm)
            return {
                "changed": False,
                "msg": msg,
                "data": {
                    "state": state,
                    "metrics": {"rpm": rpm},
                    "details": ""
                }
            }
    
    # Sensor not found
    return {
        "changed": False,
        "msg": "Sensor " + item + " not found in SNMP data",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }
