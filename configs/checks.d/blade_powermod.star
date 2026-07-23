_POWERMOD_BASE_OID = ".1.3.6.1.4.1.2.3.51.2.2.4.1.1"

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, _POWERMOD_BASE_OID
        ], mutates=False)
        
        lines = res.stdout.splitlines()
        
        entries = []  # list of (idx, value)
        for line in lines:
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            val_part = line[eq_idx+1:].strip()
            
            parts = oid_part.rsplit(".", 1)
            if len(parts) != 2:
                continue
            idx_str = parts[1]
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            
            colon_idx = val_part.find(":")
            val = val_part[colon_idx+1:].strip() if colon_idx != -1 else val_part
            
            entries.append((idx, val))
        
        modules = {}
        for idx, val in entries:
            if idx not in modules:
                modules[idx] = []
            modules[idx].append(val)
        
        discovery = []
        for idx in sorted(modules.keys()):
            entries_list = modules[idx]
            if len(entries_list) < 4:
                continue
            name = entries_list[0]
            present = entries_list[1]
            
            if present == "1":
                discovery.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d power modules" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, _POWERMOD_BASE_OID
    ], mutates=False)
    
    entries = []  # list of (idx, value)
    for line in res.stdout.splitlines():
        eq_idx = line.find("=")
        if eq_idx == -1:
            continue
        oid_part = line[:eq_idx].strip()
        val_part = line[eq_idx+1:].strip()
        
        parts = oid_part.rsplit(".", 1)
        if len(parts) != 2:
            continue
        idx_str = parts[1]
        if not idx_str.isdigit():
            continue
        idx = int(idx_str)
        
        colon_idx = val_part.find(":")
        val = val_part[colon_idx+1:].strip() if colon_idx != -1 else val_part
        
        entries.append((idx, val))
    
    modules = {}
    for idx, val in entries:
        if idx not in modules:
            modules[idx] = []
        modules[idx].append(val)
    
    for idx in modules:
        m = modules[idx]
        if len(m) >= 4:
            name = m[0]
            if name == item:
                present = m[1]
                status = m[2]
                text = m[3]
                
                if present != "1":
                    return {
                        "changed": False,
                        "msg": "Not present",
                        "data": {
                            "state": "CRIT",
                            "metrics": {},
                            "details": ""
                        }
                    }
                
                state = "OK" if status == "1" else "CRIT"
                
                return {
                    "changed": False,
                    "msg": text if text else ("OK" if state == "OK" else "Failed"),
                    "data": {
                        "state": state,
                        "metrics": {},
                        "details": ""
                    }
                }
    
    return {
        "changed": False,
        "msg": "power module not found: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }
