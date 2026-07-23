PRESENT_MAP = {1: "other", 2: "absent", 3: "present"}
STATUS_MAP = {
    1: ("CRIT", "Other"),
    2: ("OK", "Ok"),
    3: ("WARN", "Degraded"),
    4: ("CRIT", "Failed"),
}

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        base_oid = ".1.3.6.1.4.1.232.22.2.4.1.1.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        blades = {}
        current_index = ""
        
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0].strip()
            value_str = parts[1].strip()
            
            if not oid_full.startswith(base_oid + "."):
                continue
            suffix = oid_full[len(base_oid)+1:]
            
            value = value_str
            if value_str.startswith("INTEGER:"):
                value = value_str[8:].strip()
            elif value_str.startswith("STRING:"):
                value = value_str[7:].strip().strip('"')
            
            if suffix == "3":
                current_index = value
                if current_index not in blades:
                    blades[current_index] = {"index": current_index}
            elif suffix == "12":
                if current_index and current_index in blades:
                    if value.isdigit():
                        blades[current_index]["present"] = int(value)
                    else:
                        blades[current_index]["present"] = 0
            elif suffix == "21":
                if current_index and current_index in blades:
                    if value.isdigit():
                        blades[current_index]["status"] = int(value)
                    else:
                        blades[current_index]["status"] = 0
            elif suffix == "17":
                if current_index and current_index in blades:
                    blades[current_index]["product"] = value
            elif suffix == "4":
                if current_index and current_index in blades:
                    blades[current_index]["name"] = value
            elif suffix == "16":
                if current_index and current_index in blades:
                    blades[current_index]["serial"] = value
        
        discovery_list = []
        for idx, blade in blades.items():
            present_val = blade.get("present", 0)
            if PRESENT_MAP.get(present_val) == "present":
                discovery_list.append({
                    "item": idx,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d blades" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    base_oid = ".1.3.6.1.4.1.232.22.2.4.1.1.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    blade_data = {}
    
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" ", 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0].strip()
        value_str = parts[1].strip()
        
        if not oid_full.startswith(base_oid + "."):
            continue
        suffix = oid_full[len(base_oid)+1:]
        
        value = value_str
        if value_str.startswith("INTEGER:"):
            value = value_str[8:].strip()
        elif value_str.startswith("STRING:"):
            value = value_str[7:].strip().strip('"')
        
        if suffix == "3":
            current_index = value
            if current_index not in blade_data:
                blade_data[current_index] = {"index": current_index}
        elif suffix == "12":
            if current_index and current_index in blade_data:
                if value.isdigit():
                    blade_data[current_index]["present"] = int(value)
                else:
                    blade_data[current_index]["present"] = 0
        elif suffix == "21":
            if current_index and current_index in blade_data:
                if value.isdigit():
                    blade_data[current_index]["status"] = int(value)
                else:
                    blade_data[current_index]["status"] = 0
        elif suffix == "17":
            if current_index and current_index in blade_data:
                blade_data[current_index]["product"] = value
        elif suffix == "4":
            if current_index and current_index in blade_data:
                blade_data[current_index]["name"] = value
        elif suffix == "16":
            if current_index and current_index in blade_data:
                blade_data[current_index]["serial"] = value
    
    blade = blade_data.get(item, {})
    
    present_val = blade.get("present", 0)
    present_state = PRESENT_MAP.get(present_val, "absent")
    
    if present_state != "present":
        return {
            "changed": False,
            "msg": "Blade was present but is not available anymore (Present state: %s)" % present_state,
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }
    
    raw_state = blade.get("status", 0)
    if not str(raw_state).isdigit():
        raw_state = 2
    else:
        raw_state = int(raw_state)
    
    status_info = STATUS_MAP.get(raw_state, ("UNKNOWN", "Unknown"))
    state = status_info[0]
    state_readable = status_info[1]
    
    product = blade.get("product", "")
    name = blade.get("name", "")
    serial = blade.get("serial", "")
    
    summary = "Blade status is %s (Product: %s Name: %s S/N: %s)" % (
        state_readable,
        product if product else "N/A",
        name if name else "N/A",
        serial if serial else "N/A"
    )
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }