def main(ctx, params):
    # ===== Constants =====
    OID_BASE = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"
    
    PSU_STATE_MAP = {
        "1": "OK",
        "2": "OK",
        "3": "OK",
        "4": "CRIT",
        "5": "CRIT",
        "6": "OK",
        "7": "CRIT",
        "8": "CRIT",
        "9": "CRIT",
    }
    
    PSU_STATE_NAMES = {
        "1": "NotPresent",
        "2": "NotPlugged",
        "3": "Powered",
        "4": "Failed",
        "5": "PermFailure",
        "6": "Max",
        "7": "AuxFailure",
        "8": "NotPowered",
        "9": "AuxNotPowered",
    }
    
    # ===== Discovery Mode =====
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            OID_BASE
        ], mutates=False)
        
        psus = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            
            oid_with_suffix = parts[0].strip()
            value_str = parts[1].strip()
            
            rest = oid_with_suffix[len(OID_BASE):]
            if not rest.startswith("."):
                continue
            rest = rest[1:]
            dot_idx = rest.find(".")
            if dot_idx == -1:
                continue
            idx_str = rest[:dot_idx]
            field_idx_str = rest[dot_idx+1:]
            if not idx_str.isdigit() or not field_idx_str.isdigit():
                continue
            idx = int(idx_str)
            field_idx = int(field_idx_str)
            
            value = value_str
            if ": " in value_str:
                value = value_str.split(": ", 1)[1].strip().strip('"')
            
            if idx not in psus:
                psus[idx] = {}
            psus[idx][field_idx] = value
        
        items = []
        for idx, fields in psus.items():
            state = fields.get(2, "")
            if state in ["1", "2"]:
                continue
            
            model = fields.get(9, "Unknown")
            item_name = "%s %d" % (model, idx) if model else "%d" % idx
            
            items.append({
                "item": item_name,
                "params": {},
                "metrics": ["psu_status"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d PSUs" % len(items),
            "data": {"discovery": items}
        }
    
    # ===== Check Mode =====
    item = params.get("item", "")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        OID_BASE
    ], mutates=False)
    
    psus = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        
        oid_with_suffix = parts[0].strip()
        value_str = parts[1].strip()
        
        rest = oid_with_suffix[len(OID_BASE):]
        if not rest.startswith("."):
            continue
        rest = rest[1:]
        dot_idx = rest.find(".")
        if dot_idx == -1:
            continue
        idx_str = rest[:dot_idx]
        field_idx_str = rest[dot_idx+1:]
        if not idx_str.isdigit() or not field_idx_str.isdigit():
            continue
        idx = int(idx_str)
        field_idx = int(field_idx_str)
        
        value = value_str
        if ": " in value_str:
            value = value_str.split(": ", 1)[1].strip().strip('"')
        
        if idx not in psus:
            psus[idx] = {}
        psus[idx][field_idx] = value
    
    # Find the specific PSU
    psu = None
    for idx, fields in psus.items():
        model = fields.get(9, "Unknown")
        item_name = "%s %d" % (model, idx) if model else "%d" % idx
        if item_name == item:
            psu = fields
            break
    
    if psu == None:
        return {
            "changed": False,
            "msg": "PSU not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract values with safe defaults
    state = str(psu.get(2, ""))
    failures_str = psu.get(3, "0")
    failures = int(failures_str) if failures_str.isdigit() else 0
    
    temp_str = psu.get(4, "0.0")
    # Handle float parsing safely: check if valid number string
    temp_val = temp_str
    temp_val_clean = temp_val.replace('.', '').replace('-', '')
    if temp_val_clean.isdigit():
        temperature = float(temp_val)
    else:
        temperature = 0.0
    
    voltage_info = psu.get(5, "")
    wattage_curr_str = psu.get(6, "0")
    wattage_curr = int(wattage_curr_str) if wattage_curr_str.isdigit() else 0
    wattage_max_str = psu.get(7, "0")
    wattage_max = int(wattage_max_str) if wattage_max_str.isdigit() else 0
    last_call_str = psu.get(8, "0")
    last_call = int(last_call_str) if last_call_str.isdigit() else 0
    
    # Determine state based on PSU state mapping
    state_value = PSU_STATE_MAP.get(state, "CRIT")
    
    # Format uptime text
    def format_timespan(seconds):
        if seconds < 60:
            return "%d s" % seconds
        elif seconds < 3600:
            return "%d m %d s" % (seconds // 60, seconds % 60)
        elif seconds < 86400:
            hours = seconds // 3600
            minutes = (seconds % 3600) // 60
            return "%d h %d m" % (hours, minutes)
        else:
            days = seconds // 86400
            hours = (seconds % 86400) // 3600
            return "%d d %d h" % (days, hours)
    
    uptime_str = format_timespan(last_call)
    
    # Determine Checkmk state
    if state_value == "CRIT":
        state = "CRIT"
    else:
        state = "OK"
    
    # Build summary message
    state_name = PSU_STATE_NAMES.get(state, "Unknown")
    summary = "PSU Status: %s, Uptime: %s" % (state_name, uptime_str)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "psu_status": 1 if state == "OK" else 2,
                "failure_count": failures,
                "temperature": temperature,
                "wattage": wattage_curr
            },
            "details": "Voltage Info: %s, Maximum Wattage: %dW" % (voltage_info, wattage_max)
        }
    }