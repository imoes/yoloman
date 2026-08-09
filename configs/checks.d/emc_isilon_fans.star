EMC_ISILON_FANS_BASE_OID = ".1.3.6.1.4.1.12124.2.53.1"
EMC_ISILON_FANS_NAME_OID = ".3"
EMC_ISILON_FANS_VALUE_OID = ".4"

def _isilon_fan_item_name(sensor_name):
    name = sensor_name.replace("Fan", "")
    parts = name.split("(")
    return parts[0].strip()

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, EMC_ISILON_FANS_BASE_OID
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP query failed",
                "data": {"discovery": []}
            }
        
        fans = []
        current_name = None
        current_value = None
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            
            oid = parts[0].strip()
            value_str = parts[1].strip()
            if ":" in value_str:
                value_str = value_str.split(":", 1)[1].strip()
            
            if oid.endswith(EMC_ISILON_FANS_NAME_OID):
                current_name = value_str.strip('"')
            elif oid.endswith(EMC_ISILON_FANS_VALUE_OID):
                current_value = value_str.strip('"')
            
            if current_name != None and current_value != None:
                item = _isilon_fan_item_name(current_name)
                value = current_value.strip('"').split()[0]
                rpm = float(value) if value.replace('.', '', 1).replace('-', '', 1).isdigit() else 0.0
                
                fans.append({
                    "item": item,
                    "params": {"lower": (3000.0, 2500.0)},
                    "metrics": ["rpm"]
                })
                current_name = None
                current_value = None
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(fans),
            "data": {"discovery": fans}
        }
    
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, EMC_ISILON_FANS_BASE_OID
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    fan_data = []
    current_name = None
    current_value = None
    
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        
        parts = line.split(" = ")
        if len(parts) < 2:
            continue
        
        oid = parts[0].strip()
        value_str = parts[1].strip()
        if ":" in value_str:
            value_str = value_str.split(":", 1)[1].strip()
        
        if oid.endswith(EMC_ISILON_FANS_NAME_OID):
            current_name = value_str.strip('"')
        elif oid.endswith(EMC_ISILON_FANS_VALUE_OID):
            current_value = value_str.strip('"')
            
            if current_name != None and current_value != None:
                value = current_value.strip('"')
                rpm = float(value) if value.replace('.', '', 1).replace('-', '', 1).isdigit() else 0.0
                
                fan_data.append({
                    "name": current_name,
                    "item": _isilon_fan_item_name(current_name),
                    "rpm": rpm
                })
                current_name = None
                current_value = None
    
    found = False
    rpm = 0.0
    for fan in fan_data:
        if fan["item"] == item:
            found = True
            rpm = fan["rpm"]
            break
    
    if not found:
        return {
            "changed": False,
            "msg": "fan not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    params_lower = params.get("lower", (3000.0, 2500.0))
    warn_rpm = params_lower[0]
    crit_rpm = params_lower[1]
    
    if rpm <= crit_rpm:
        state = "CRIT"
    elif rpm <= warn_rpm:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "%s RPM: %f" % (item, rpm),
        "data": {
            "state": state,
            "metrics": {"rpm": rpm},
            "details": ""
        }
    }
