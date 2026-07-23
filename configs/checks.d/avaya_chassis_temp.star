# Module-level constants
DETECT_OID = ".1.3.6.1.2.1.1.2.0"
AVAYA_ENTERPRISE_OID = ".1.3.6.1.4.1.2272"
AVAYA_TEMP_OID = ".1.3.6.1.4.1.2272.1.100.1.2"
DEFAULT_WARN = 55.0
DEFAULT_CRIT = 60.0

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Discover by checking if Avaya device exists (via sysObjectID)
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), DETECT_OID], mutates=False)
        if res.rc != 0:
            # No Avaya device detected -> empty discovery
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Check if sysObjectID contains Avaya enterprise OID
        output = res.stdout.strip()
        if AVAYA_ENTERPRISE_OID in output:
            return {"changed": False, "msg": "discovered 1 items",
                    "data": {"discovery": [{"item": "Chassis",
                                           "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                                           "metrics": ["temp"]}]}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}
    
    # Check mode for item
    item = params.get("item", "Chassis")
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    
    # Get temperature value from SNMP
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), AVAYA_TEMP_OID], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse temperature from output: "<OID> = INTEGER: <value>"
    output = res.stdout.strip()
    parts = output.split(":")
    if len(parts) < 2:
        return {"changed": False, "msg": "could not parse temperature value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_str = parts[-1].strip()
    # Guard: only parse if value_str is a valid integer string
    temp_str = value_str if value_str.isdigit() else ""
    temp = int(temp_str) if temp_str != "" else None
    
    if temp == None:
        return {"changed": False, "msg": "could not parse temperature value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Determine state based on thresholds
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Temperature: %d C" % temp
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temp": float(temp)}, "details": ""}}
