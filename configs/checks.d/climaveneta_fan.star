# Map of SNMP OIDs used
_BASE_OID = ".1.3.6.1.4.1.9839.2.1.2"
_FAN1_OID = ".1.3.6.1.4.1.9839.2.1.2.42"
_FAN2_OID = ".1.3.6.1.4.1.9839.2.1.2.43"

# Default thresholds (from Checkmk plugin)
_DEFAULT_LOWER_WARN = 200
_DEFAULT_LOWER_CRIT = 100

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, _BASE_OID], mutates=False)
        
        # Parse output: look for Fan section values
        fan_values = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_part, val_part = parts
            oid_part = oid_part.strip()
            val_part = val_part.strip()
            if val_part.startswith("INTEGER: "):
                val = val_part[9:]
            elif val_part.startswith("Integer32: "):
                val = val_part[11:]
            else:
                continue
            
            if oid_part == _FAN1_OID:
                fan_values["1"] = val
            elif oid_part == _FAN2_OID:
                fan_values["2"] = val
        
        # Build discovery result
        discovered = []
        for fan_num in ["1", "2"]:
            if fan_num in fan_values:
                discovered.append({
                    "item": fan_num,
                    "params": {"lower": (_DEFAULT_LOWER_WARN, _DEFAULT_LOWER_CRIT)},
                    "metrics": ["fan_speed"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode
    item = params.get("item", "")
    if item not in ["1", "2"]:
        return {
            "changed": False,
            "msg": "invalid fan item: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, _FAN1_OID if item == "1" else _FAN2_OID], mutates=False)
    
    # Parse output: "OID = INTEGER: value"
    rpm = 0
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_part, val_part = parts
        val_part = val_part.strip()
        if val_part.startswith("INTEGER: "):
            val_str = val_part[9:].strip()
            if val_str.isdigit():
                rpm = int(val_str)
            break
        elif val_part.startswith("Integer32: "):
            val_str = val_part[11:].strip()
            if val_str.isdigit():
                rpm = int(val_str)
            break
    
    # Get thresholds from params (Checkmk defaults)
    lower = params.get("lower", (_DEFAULT_LOWER_WARN, _DEFAULT_LOWER_CRIT))
    warn = lower[0] if lower and len(lower) >= 2 else _DEFAULT_LOWER_WARN
    crit = lower[1] if lower and len(lower) >= 2 else _DEFAULT_LOWER_CRIT
    
    # Determine state: lower levels -> WARN if <= warn, CRIT if <= crit
    if rpm <= crit:
        state = "CRIT"
    elif rpm <= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Fan %s: %d RPM" % (item, rpm)
    details = ""
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"fan_speed": rpm},
            "details": details
        }
    }
