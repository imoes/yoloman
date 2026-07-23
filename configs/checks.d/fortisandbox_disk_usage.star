def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.12356.118.3.1.5"
        ], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "SNMP query failed for disk usage",
                    "data": {"discovery": []}}
        
        used = None
        for line in res.stdout.splitlines():
            line = line.strip()
            if line.endswith("INTEGER:"):
                continue
            parts = line.split(" = INTEGER: ")
            if len(parts) == 2:
                val_str = parts[1].strip()
                if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                    used = int(val_str)
                    break
        
        if used == None:
            return {"changed": False, "msg": "disk usage not found in SNMP output",
                    "data": {"discovery": []}}
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.12356.118.3.1.6"
        ], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "SNMP query failed for disk capacity",
                    "data": {"discovery": []}}
        
        cap = None
        for line in res.stdout.splitlines():
            line = line.strip()
            if line.endswith("INTEGER:"):
                continue
            parts = line.split(" = INTEGER: ")
            if len(parts) == 2:
                val_str = parts[1].strip()
                if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                    cap = int(val_str)
                    break
        
        if cap == None:
            return {"changed": False, "msg": "disk capacity not found in SNMP output",
                    "data": {"discovery": []}}
        
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "system",
                        "params": {
                            "levels": [80.0, 90.0],
                            "show_levels": "onwarn",
                            "show_used": True,
                            "show_free": True,
                            "range": None,
                            "perfdata": True,
                            "unit": "B",
                            "group_name": None,
                            "inodes_levels": [100.0, 100.0]
                        },
                        "metrics": ["used_percent"]
                    }
                ]
            }
        }
    
    item = params.get("item", "")
    if item != "system":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.12356.118.3.1.5"
    ], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP query failed for disk usage",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    used = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if line.endswith("INTEGER:"):
            continue
        parts = line.split(" = INTEGER: ")
        if len(parts) == 2:
            val_str = parts[1].strip()
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                used = int(val_str)
                break
    
    if used == None:
        return {
            "changed": False,
            "msg": "disk usage not found in SNMP output",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.12356.118.3.1.6"
    ], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP query failed for disk capacity",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    cap = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if line.endswith("INTEGER:"):
            continue
        parts = line.split(" = INTEGER: ")
        if len(parts) == 2:
            val_str = parts[1].strip()
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                cap = int(val_str)
                break
    
    if cap == None:
        return {
            "changed": False,
            "msg": "disk capacity not found in SNMP output",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    levels_tuple = params.get("levels")
    if levels_tuple != None and len(levels_tuple) == 2:
        warn = levels_tuple[0]
        crit = levels_tuple[1]
    else:
        warn = 80.0
        crit = 90.0
    
    if cap <= 0:
        return {
            "changed": False,
            "msg": "disk capacity is zero or negative",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    used_percent = float(used) * 100.0 / float(cap)
    
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Size: %s, Free: %s, Used: %f%%" % (str(cap), str(cap - used), used_percent)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent},
            "details": ""
        }
    }
