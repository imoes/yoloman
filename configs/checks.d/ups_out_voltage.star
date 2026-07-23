def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.2.1.33.1.4.4.1"
        ], mutates=False)
        
        lines = res.stdout.splitlines() if res.stdout else []
        discovered = []
        
        for line in lines:
            if not line.strip():
                continue
            if "=" not in line:
                continue
            oid_part, value_part = line.split("=", 1)
            oid = oid_part.strip()
            value = value_part.strip()
            
            if oid.endswith(".2"):
                base_prefix = ".1.3.6.1.2.1.33.1.4.4.1."
                if oid.startswith(base_prefix):
                    phase_id = oid[len(base_prefix):]
                    voltage = 0
                    if ":" in value:
                        voltage_str = value.split(":", 1)[1].strip()
                        if voltage_str.isdigit():
                            voltage = int(voltage_str)
                    if voltage > 0:
                        discovered.append({
                            "item": phase_id,
                            "params": {"levels_upper": (None, None), "levels_lower": (210.0, 180.0)},
                            "metrics": ["out_voltage"]
                        })
        
        return {
            "changed": False,
            "msg": "discovered %d voltage phases" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode for a specific item (phase)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")
    
    base_oid = ".1.3.6.1.2.1.33.1.4.4.1." + item + ".2"
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        base_oid
    ], mutates=False)
    
    lines = res.stdout.splitlines() if res.stdout else []
    
    voltage = None
    for line in lines:
        if not line.strip():
            continue
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        value = value_part.strip()
        
        if ":" in value:
            voltage_str = value.split(":", 1)[1].strip()
            if voltage_str.isdigit():
                voltage = int(voltage_str)
                break
    
    warn_lower, crit_lower = params.get("levels_lower", (210.0, 180.0))
    
    if voltage == None:
        return {
            "changed": False,
            "msg": "no data found for phase " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    if voltage <= crit_lower:
        state = "CRIT"
    elif voltage <= warn_lower:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "OUT voltage phase %s: %dV" % (item, voltage),
        "data": {
            "state": state,
            "metrics": {"out_voltage": voltage},
            "details": ""
        }
    }