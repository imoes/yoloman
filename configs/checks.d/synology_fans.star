# Fan status check for Synology devices via SNMP
# Translated from checkmk.synology_fans

FAN_OID_SYSTEM = ".1.3.6.1.4.1.6574.1.4.1"
FAN_OID_CPU = ".1.3.6.1.4.1.6574.1.4.2"

FAN_STATUS_NORMAL = 1
FAN_STATUS_FAILURE = 2

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: enumerate fans present on this host
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            FAN_OID_SYSTEM, FAN_OID_CPU
        ], mutates=False)
        
        if res.rc != 0:
            # Cannot discover — skip (Checkmk would not create services)
            return {"changed": False, "msg": "no fans discovered", "data": {"discovery": []}}
        
        # Parse snmpwalk output: lines like ".1.3.6.1.4.1.6574.1.4.1 = INTEGER: 1"
        fans = []
        lines = res.stdout.splitlines()
        for line in lines:
            if " = INTEGER: " not in line:
                continue
            parts = line.split(" = INTEGER: ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            # Guard: check if val_part is a digit string before converting
            if not val_part.isdigit():
                continue
            val = int(val_part)
            
            if oid_part == FAN_OID_SYSTEM:
                fans.append({"item": "System", "params": {}, "metrics": []})
            elif oid_part == FAN_OID_CPU:
                fans.append({"item": "CPU", "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d fans" % len(fans),
                "data": {"discovery": fans}}
    
    # Check mode: validate single fan
    item = params.get("item", "")
    
    # Fetch fan statuses via snmpget
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        FAN_OID_SYSTEM, FAN_OID_CPU
    ], mutates=False)
    
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "failed to get fan data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Build lookup of OID -> status
    fan_status_map = {}
    lines = res.stdout.splitlines()
    for line in lines:
        if " = INTEGER: " not in line:
            continue
        parts = line.split(" = INTEGER: ")
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        val = parts[1].strip()
        if not val.isdigit():
            continue
        val_int = int(val)
        if oid == FAN_OID_SYSTEM:
            fan_status_map["System"] = val_int
        elif oid == FAN_OID_CPU:
            fan_status_map["CPU"] = val_int
    
    # Lookup requested fan item
    status_val = fan_status_map.get(item)
    if status_val == None:
        return {"changed": False, "msg": "no such fan: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Determine state
    if status_val == FAN_STATUS_NORMAL:
        state = "OK"
        summary = "Operating normally"
    elif status_val == FAN_STATUS_FAILURE:
        state = "CRIT"
        summary = "Fan failed"
    else:
        state = "UNKNOWN"
        summary = "Unknown fan status: %d" % status_val
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}