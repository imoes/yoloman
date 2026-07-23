# Constants for SNMP OIDs
_RMS200_TEMP_BASE_OID = ".1.3.6.1.4.1.1909.13.1.1.1"
_SYSTEM_OID = ".1.3.6.1.2.1.1.2.0"
_SYSTEM_RMS200_VALUE = ".1.3.6.1.4.1.1909.13"

def _snmp_parse_line(line):
    """Parse a single snmpwalk output line into (oid, type, value)."""
    if line == None:
        return None
    idx = line.find(" = ")
    if idx == -1:
        return None
    oid_part = line[:idx]
    rest = line[idx + 3:]
    colon_idx = rest.find(": ")
    if colon_idx == -1:
        return None
    stype = rest[:colon_idx]
    svalue = rest[colon_idx + 2:]
    return [oid_part, stype, svalue]

def main(ctx, params):
    if params.get("_discover"):
        # Detect RMS200 device by checking system OID
        sys_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                           params.get("host", "localhost"), _SYSTEM_OID], mutates=False)
        if sys_res.rc != 0 or sys_res.stdout == "":
            return {"changed": False, "msg": "snmpwalk failed or no response",
                    "data": {"discovery": []}}
        
        # Check if this is an RMS200 device
        is_rms200 = False
        for line in sys_res.stdout.splitlines():
            if line.strip().endswith(" = " + _SYSTEM_RMS200_VALUE):
                is_rms200 = True
                break
        
        if not is_rms200:
            return {"changed": False, "msg": "not an RMS200 device",
                    "data": {"discovery": []}}
        
        # Fetch temperature section: .1.3.6.1.4.1.1909.13.1.1.1.{1,2,5}
        # We need all three OIDs per entry; use walk on base OID
        temp_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                            params.get("host", "localhost"), _RMS200_TEMP_BASE_OID], mutates=False)
        
        if temp_res.rc != 0 or temp_res.stdout == "":
            return {"changed": False, "msg": "no temperature data available",
                    "data": {"discovery": []}}
        
        # Group by instance index: OID pattern .base.index.oid_num
        sensors = {}
        for line in temp_res.stdout.splitlines():
            parsed = _snmp_parse_line(line.strip())
            if parsed == None:
                continue
            oid_str = parsed[0]
            if not oid_str.startswith(_RMS200_TEMP_BASE_OID + "."):
                continue
            rest = oid_str[len(_RMS200_TEMP_BASE_OID + "."):]
            parts = rest.split(".", 1)
            if len(parts) != 2:
                continue
            idx_str = parts[0]
            oid_num_str = parts[1]
            
            # We expect only indices 1,2,3 with oid numbers 1,2,3 respectively:
            # 1 -> name, 2 -> state, 3 -> temperature *100
            if not idx_str.isdigit() or not oid_num_str.isdigit():
                continue
            idx = int(idx_str)
            oid_num = int(oid_num_str)
            
            if idx not in sensors:
                sensors[idx] = {"name": "", "state": "", "temp_raw": "-27300"}
            if oid_num == 1:
                # Strip quotes if present
                val = parsed[2].strip('"')
                sensors[idx]["name"] = val
            elif oid_num == 2:
                sensors[idx]["state"] = parsed[2]
            elif oid_num == 3:
                sensors[idx]["temp_raw"] = parsed[2]
        
        discovery = []
        for idx, data in sensors.items():
            # Skip if sensor not connected (temp_raw == "-27300")
            if data["temp_raw"] == "-27300":
                continue
            item = data["name"]
            if item == "":
                item = str(idx)
            discovery.append({"item": item, "params": {"levels": [25.0, 28.0]},
                              "metrics": ["temp"]})
        
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Re-fetch all sensor data to get the requested item
    temp_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On",
                        host, _RMS200_TEMP_BASE_OID], mutates=False)
    
    if temp_res.rc != 0 or temp_res.stdout == "":
        return {"changed": False, "msg": "no temperature data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse and group sensor data
    sensors = {}
    for line in temp_res.stdout.splitlines():
        parsed = _snmp_parse_line(line.strip())
        if parsed == None:
            continue
        oid_str = parsed[0]
        if not oid_str.startswith(_RMS200_TEMP_BASE_OID + "."):
            continue
        rest = oid_str[len(_RMS200_TEMP_BASE_OID + "."):]
        parts = rest.split(".", 1)
        if len(parts) != 2:
            continue
        idx_str = parts[0]
        oid_num_str = parts[1]
        
        if not idx_str.isdigit() or not oid_num_str.isdigit():
            continue
        idx = int(idx_str)
        oid_num = int(oid_num_str)
        
        if idx not in sensors:
            sensors[idx] = {"name": "", "state": "", "temp_raw": "-27300"}
        if oid_num == 1:
            val = parsed[2].strip('"')
            sensors[idx]["name"] = val
        elif oid_num == 2:
            sensors[idx]["state"] = parsed[2]
        elif oid_num == 3:
            sensors[idx]["temp_raw"] = parsed[2]
    
    # Find requested item
    temp_celsius = None
    sensor_state = ""
    for idx, data in sensors.items():
        it = data["name"]
        if it == "":
            it = str(idx)
        if it == item:
            if data["temp_raw"] == "-27300":
                temp_celsius = None
            else:
                temp_celsius = float(data["temp_raw"]) / 100.0
            sensor_state = data["state"]
            break
    
    # If item not found or no sensor connected
    if temp_celsius == None:
        return {"changed": False, "msg": "sensor '%s' not found or not connected" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Apply thresholds
    levels = params.get("levels", [25.0, 28.0])
    warn = levels[0] if len(levels) >= 1 else 25.0
    crit = levels[1] if len(levels) >= 2 else 28.0
    
    state = "OK"
    if temp_celsius >= crit:
        state = "CRIT"
    elif temp_celsius >= warn:
        state = "WARN"
    
    # Build message
    summary = "Temperature: %f C" % temp_celsius
    if sensor_state != "":
        summary += " (%s)" % sensor_state
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"temp": temp_celsius}, "details": ""}}