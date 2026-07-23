def main(ctx, params):
    # Module-level constants
    SNMP_BASE = ".1.3.6.1.4.1.318.1.1.13.3.2.2.2"
    OID_NAMES = ["7", "9", "11", "24", "26"]
    ITEM_NAMES = ["Rack Inlet", "Supply Air", "Return Air", "Entering Fluid", "Leaving Fluid"]
    DEFAULT_LEVELS = (30.0, 35.0)
    
    # Discover mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), SNMP_BASE
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        # Parse snmpwalk output: "<oid> = <type>: <value>"
        parsed = {}
        lines = res.stdout.splitlines()
        for i, oid_suffix in enumerate(OID_NAMES):
            oid = SNMP_BASE + "." + oid_suffix
            for line in lines:
                if line.startswith(oid + " = "):
                    value_str = line.split(" = ")[1].split(": ", 1)[1].strip()
                    if value_str not in ["", "-1"] and value_str.isdigit():
                        parsed[ITEM_NAMES[i]] = float(value_str) / 10
                    break
        
        # Build discovery results
        discovery = []
        for key in parsed:
            discovery.append({
                "item": key,
                "params": {"levels": DEFAULT_LEVELS},
                "metrics": ["temperature"]
            })
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode (non-discovery)
    item = params.get("item", "")
    levels = params.get("levels", DEFAULT_LEVELS)
    warn, crit = levels[0], levels[1]
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), SNMP_BASE + "." + OID_NAMES[ITEM_NAMES.index(item)] if item in ITEM_NAMES else "1"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP get failed for item " + item + ": " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse single snmpget output: "<oid> = <type>: <value>"
    value_str = res.stdout.strip().split(" = ")[1].split(": ", 1)[1].strip()
    if value_str in ["", "-1"] or not value_str.isdigit():
        return {"changed": False, "msg": "No valid data for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temperature = float(value_str) / 10
    if temperature >= crit:
        state = "CRIT"
    elif temperature >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {"changed": False,
            "msg": "Temperature: %f C (warn at %f C, crit at %f C)" % (temperature, warn, crit),
            "data": {
                "state": state,
                "metrics": {"temperature": temperature},
                "details": ""
            }}
