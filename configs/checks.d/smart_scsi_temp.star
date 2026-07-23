# Top-level constants
DEFAULT_LEVELS = (35.0, 40.0)  # (warn, crit) from check_default_parameters

def _parse_smart_json_output(json_str):
    """Parse smartctl -j JSON output for temperature data."""
    if json_str == None or json_str == "":
        return None
    # Guard instead of try/except: only attempt decode if looks like JSON
    stripped = json_str.strip()
    if not stripped.startswith("{") and not stripped.startswith("["):
        return None
    # Use a safe approach: decode only if no obvious errors
    data = json.decode(json_str) if stripped else None
    if data == None or type(data) != "dict":
        return None
    return data

def _extract_temperature(data):
    """Extract current and drive_trip temperatures from parsed JSON data."""
    if data == None:
        return None, None
    
    # Try main drive section first
    drive = data.get("drives", [])
    if type(drive) != "list" or len(drive) == 0:
        return None, None
    
    d = drive[0]
    if type(d) != "dict":
        return None, None
    
    # Current temperature from temperature.current
    current = None
    temp = d.get("temperature")
    if type(temp) == "dict":
        current = temp.get("current")
        if type(current) == "string":
            current = int(current) if current.isdigit() else None
    
    # Drive trip temperature
    drive_trip = None
    temp = d.get("temperature")
    if type(temp) == "dict":
        drive_trip = temp.get("drive_trip")
        if type(drive_trip) == "string":
            drive_trip = int(drive_trip) if drive_trip.isdigit() else None
    
    return current, drive_trip

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: run smartctl -j for all devices and discover those with valid SCSI temps
        res = ctx.run(["smartctl", "-j", "--scan"], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "discovery failed", 
                    "data": {"discovery": []}}
        
        scan_data = _parse_smart_json_output(res.stdout)
        if scan_data == None:
            return {"changed": False, "msg": "invalid scan output",
                    "data": {"discovery": []}}
        
        devices = scan_data.get("devices", [])
        if type(devices) != "list":
            return {"changed": False, "msg": "invalid scan output",
                    "data": {"discovery": []}}
        
        discovered = []
        for dev in devices:
            if type(dev) != "dict":
                continue
            dev_path = dev.get("name", "")
            if dev_path == "":
                continue
            
            # Get device-specific JSON
            dev_res = ctx.run(["smartctl", "-j", dev_path], mutates=False)
            if dev_res.rc != 0:
                continue
            
            data = _parse_smart_json_output(dev_res.stdout)
            if data == None:
                continue
            
            current, drive_trip = _extract_temperature(data)
            
            # Skip if current or drive_trip are zero (controller values, not drive values)
            if current == None:
                continue
            if current == 0 and drive_trip == 0:
                continue
            
            # Item is the device path (e.g., "/dev/sda")
            item = dev_path
            discovered.append({
                "item": item,
                "params": {"levels": DEFAULT_LEVELS},
                "metrics": ["temp"]
            })
        
        return {"changed": False, "msg": "discovered %d devices" % len(discovered),
                "data": {"discovery": discovered}}
    
    # Check mode: get temperature for specific item
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Run smartctl to get JSON data for this device
    res = ctx.run(["smartctl", "-j", item], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot get device data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = _parse_smart_json_output(res.stdout)
    if data == None:
        return {"changed": False, "msg": "cannot parse device data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    current, drive_trip = _extract_temperature(data)
    
    if current == None:
        return {"changed": False, "msg": "no temperature data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Skip if current and drive_trip are zero (controller values)
    if current == 0 and drive_trip == 0:
        return {"changed": False, "msg": "temperature is controller value (zero)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract thresholds
    levels = params.get("levels", DEFAULT_LEVELS)
    warn = levels[0]
    crit = levels[1]
    
    # Determine state (check_temperature logic: upper levels)
    state = "OK"
    if current >= crit:
        state = "CRIT"
    elif current >= warn:
        state = "WARN"
    
    msg = "Temperature: %f°C" % current
    return {"changed": False, "msg": msg,
            "data": {"state": state, 
                     "metrics": {"temp": current},
                     "details": ""}}