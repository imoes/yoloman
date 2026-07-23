def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.3808.1.1.1.2.2"
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".3"
        ], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            if line.strip() and "INTEGER:" in line:
                items.append({
                    "item": "Battery",
                    "params": {},
                    "metrics": ["temperature"]
                })
                break
        
        return {
            "changed": False,
            "msg": "discovered %d services" % len(items),
            "data": {"discovery": items}
        }
    
    item = params.get("item", "")
    if item != "Battery":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".3"
    ], mutates=False)
    
    temperature = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if ".3" in line:
            parts = line.split(" = ")
            if len(parts) == 2:
                value_str = parts[1].strip()
                if value_str.startswith("INTEGER:"):
                    suffix = value_str[len("INTEGER:"):].strip()
                    if suffix and (suffix[0] == "-" or suffix.isdigit()):
                        temperature = int(suffix)
                        break
    
    if temperature == None:
        return {
            "changed": False,
            "msg": "no temperature data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    warn = params.get("levels_upper", (None, None))[0]
    crit = params.get("levels_upper", (None, None))[1]
    
    state = "OK"
    if crit != None and temperature >= crit:
        state = "CRIT"
    elif warn != None and temperature >= warn:
        state = "WARN"
    
    msg = "Temperature: %d C" % temperature
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": float(temperature)},
            "details": ""
        }
    }