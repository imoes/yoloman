def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Base OID for quanta_fan section
        base_oid = ".1.3.6.1.4.1.7244.1.2.1.3.3.1"
        
        # Fetch all required OIDs in one walk
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host,
            base_oid
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        # Parse SNMP output
        lines = res.stdout.splitlines()
        
        # Prepare data storage for each fan
        fans_data = {}  # keyed by item (device name)
        
        # Process each line
        for line in lines:
            line = line.strip()
            if not line:
                continue
            
            # Format: OID = TYPE: value
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value_part = parts[1].strip()
            # Remove type prefix if present (e.g., "INTEGER: " or "STRING: ")
            if ":" in value_part:
                value = value_part.split(":", 1)[1].strip()
            else:
                value = value_part
            value = value.strip('"')
            
            # Extract the numeric suffix from OID
            # OID structure: .1.3.6.1.4.1.7244.1.2.1.3.3.1.{field}.{index}
            # where field is 1-9
            oid_parts = oid.split(".")
            if len(oid_parts) < 11:
                continue
            
            field_num_str = oid_parts[-2]
            index_str = oid_parts[-1]
            
            # Check if numeric before converting
            if not field_num_str.replace("-", "", 1).isdigit():
                continue
            field_num = int(field_num_str)
            if not index_str.replace("-", "", 1).isdigit():
                continue
            index = int(index_str)
            
            # Map field numbers to names
            field_map = {
                1: "index",
                2: "status",
                3: "name",
                4: "value",
                6: "upper_crit",
                7: "upper_warn",
                8: "lower_warn",
                9: "lower_crit"
            }
            
            field_name = field_map.get(field_num)
            if not field_name:
                continue
            
            # Get the device name for indexing
            dev_name = ""
            if field_name == "name":
                dev_name = value
            else:
                # Find existing name for this index by scanning data we've collected
                for name, fan_data in fans_data.items():
                    if fan_data.get("index") == str(index):
                        dev_name = name
                        break
                if not dev_name:
                    dev_name = str(index)
            
            # Initialize fan_data if not exists
            if dev_name not in fans_data:
                fans_data[dev_name] = {
                    "index": str(index)
                }
            
            # Store the value
            fans_data[dev_name][field_name] = value
        
        # Build discovery result
        discovery_items = []
        for dev_name, data in fans_data.items():
            # Get default thresholds from the data (or None if not available)
            upper_warn = None
            upper_crit = None
            lower_warn = None
            lower_crit = None
            
            # Parse upper levels
            if "upper_warn" in data and data["upper_warn"] != "-99":
                upper_warn_str = data["upper_warn"]
                if upper_warn_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (upper_warn_str.startswith("-") and upper_warn_str[1:].replace(".", "", 1).isdigit()):
                    upper_warn = float(upper_warn_str)
            
            if "upper_crit" in data and data["upper_crit"] != "-99":
                upper_crit_str = data["upper_crit"]
                if upper_crit_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (upper_crit_str.startswith("-") and upper_crit_str[1:].replace(".", "", 1).isdigit()):
                    upper_crit = float(upper_crit_str)
            
            # Parse lower levels
            if "lower_warn" in data and data["lower_warn"] != "-99":
                lower_warn_str = data["lower_warn"]
                if lower_warn_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (lower_warn_str.startswith("-") and lower_warn_str[1:].replace(".", "", 1).isdigit()):
                    lower_warn = float(lower_warn_str)
            
            if "lower_crit" in data and data["lower_crit"] != "-99":
                lower_crit_str = data["lower_crit"]
                if lower_crit_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (lower_crit_str.startswith("-") and lower_crit_str[1:].replace(".", "", 1).isdigit()):
                    lower_crit = float(lower_crit_str)
            
            discovery_items.append({
                "item": dev_name,
                "params": {
                    "upper": (upper_warn, upper_crit),
                    "lower": (lower_warn, lower_crit)
                },
                "metrics": ["speed"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")
    
    base_oid = ".1.3.6.1.4.1.7244.1.2.1.3.3.1"
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host,
        base_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    
    # Data storage for fans
    fans_data = {}
    
    # Process each line
    for line in lines:
        line = line.strip()
        if not line:
            continue
        
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value_part = parts[1].strip()
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip()
        else:
            value = value_part
        value = value.strip('"')
        
        oid_parts = oid.split(".")
        if len(oid_parts) < 11:
            continue
        
        field_num_str = oid_parts[-2]
        index_str = oid_parts[-1]
        
        if not field_num_str.replace("-", "", 1).isdigit():
            continue
        field_num = int(field_num_str)
        if not index_str.replace("-", "", 1).isdigit():
            continue
        index = int(index_str)
        
        field_map = {
            1: "index",
            2: "status",
            3: "name",
            4: "value",
            6: "upper_crit",
            7: "upper_warn",
            8: "lower_warn",
            9: "lower_crit"
        }
        
        field_name = field_map.get(field_num)
        if not field_name:
            continue
        
        dev_name = ""
        if field_name == "name":
            dev_name = value
        else:
            for name, fan_data in fans_data.items():
                if fan_data.get("index") == str(index):
                    dev_name = name
                    break
            if not dev_name:
                dev_name = str(index)
        
        if dev_name not in fans_data:
            fans_data[dev_name] = {"index": str(index)}
        
        fans_data[dev_name][field_name] = value
    
    # Find the requested item
    if item not in fans_data:
        return {"changed": False, "msg": "fan not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    fan_data = fans_data[item]
    
    # Process status
    status_raw = fan_data.get("status", "1")
    status_map = {
        "1": ("WARN", "other"),
        "2": ("UNKNOWN", "unknown"),
        "3": ("OK", "OK"),
        "4": ("WARN", "non critical upper"),
        "5": ("CRIT", "critical upper"),
        "6": ("CRIT", "non recoverable upper"),
        "7": ("WARN", "non critical lower"),
        "8": ("CRIT", "critical lower"),
        "9": ("CRIT", "non recoverable lower"),
        "10": ("CRIT", "failed")
    }
    
    status_tuple = status_map.get(status_raw, ("UNKNOWN", "unknown[%s]" % status_raw))
    status_state = status_tuple[0]
    
    # Initialize state and summary
    state = "OK"
    summary = "Status: " + status_tuple[1]
    
    # Process value and thresholds
    value = None
    if "value" in fan_data and fan_data["value"] != "-99":
        value_str = fan_data["value"]
        if value_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (value_str.startswith("-") and value_str[1:].replace(".", "", 1).isdigit()):
            value = float(value_str)
    
    if value != None:
        # Get thresholds
        params_upper = params.get("upper", (None, None))
        params_lower = params.get("lower", (None, None))
        
        # Extract from params if provided as tuples
        upper_warn = params_upper[0] if params_upper else None
        upper_crit = params_upper[1] if len(params_upper) > 1 else None
        lower_warn = params_lower[0] if params_lower else None
        lower_crit = params_lower[1] if len(params_lower) > 1 else None
        
        # Use fan defaults if not in params (parse from fan data if available)
        if upper_warn == None and "upper_warn" in fan_data and fan_data["upper_warn"] != "-99":
            upper_warn_str = fan_data["upper_warn"]
            if upper_warn_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (upper_warn_str.startswith("-") and upper_warn_str[1:].replace(".", "", 1).isdigit()):
                upper_warn = float(upper_warn_str)
        
        if upper_crit == None and "upper_crit" in fan_data and fan_data["upper_crit"] != "-99":
            upper_crit_str = fan_data["upper_crit"]
            if upper_crit_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (upper_crit_str.startswith("-") and upper_crit_str[1:].replace(".", "", 1).isdigit()):
                upper_crit = float(upper_crit_str)
        
        if lower_warn == None and "lower_warn" in fan_data and fan_data["lower_warn"] != "-99":
            lower_warn_str = fan_data["lower_warn"]
            if lower_warn_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (lower_warn_str.startswith("-") and lower_warn_str[1:].replace(".", "", 1).isdigit()):
                lower_warn = float(lower_warn_str)
        
        if lower_crit == None and "lower_crit" in fan_data and fan_data["lower_crit"] != "-99":
            lower_crit_str = fan_data["lower_crit"]
            if lower_crit_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (lower_crit_str.startswith("-") and lower_crit_str[1:].replace(".", "", 1).isdigit()):
                lower_crit = float(lower_crit_str)
        
        # Apply upper thresholds
        if upper_warn != None or upper_crit != None:
            if upper_crit != None and value >= upper_crit:
                state = "CRIT"
            elif upper_warn != None and value >= upper_warn:
                if state not in ["CRIT"]:
                    state = "WARN"
        
        # Apply lower thresholds
        if lower_warn != None or lower_crit != None:
            if lower_crit != None and value <= lower_crit:
                state = "CRIT"
            elif lower_warn != None and value <= lower_warn:
                if state not in ["CRIT"]:
                    state = "WARN"
    
    # Final state override if status was already CRIT/WARN
    if status_state in ["CRIT", "WARN"]:
        if state == "OK":
            state = status_state
    
    # Build metrics
    metrics = {}
    if value != None:
        metrics["speed"] = value
    
    # Build details
    details = ""
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details
        }
    }