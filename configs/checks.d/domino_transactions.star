# Module-level constants
SNMP_BASE_OID = ".1.3.6.1.4.1.334.72.1.1.6.3.2"
SNMP_DEFAULT_COMMUNITY = "public"
SNMP_DEFAULT_HOST = "localhost"
DEFAULT_LEVELS = (30000, 35000)  # (warn, crit)

def main(ctx, params):
    # Determine mode: discovery or check
    if params.get("_discover"):
        # Discovery: check if the SNMP section exists and yield one service
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", SNMP_DEFAULT_COMMUNITY),
            "-On", params.get("host", SNMP_DEFAULT_HOST), SNMP_BASE_OID
        ], mutates=False)
        # Check for at least one line of output (OID found)
        if res.stdout.strip() == "":
            return {"changed": False, "msg": "no Domino transactions data found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {"levels": DEFAULT_LEVELS},
                                        "metrics": ["transactions"]}]}}
    
    # Check mode for single item (item is "" for single-service checks)
    item = params.get("item", "")
    if item != "":
        return {"changed": False, "msg": "unsupported item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch the SNMP value
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", SNMP_DEFAULT_COMMUNITY),
        "-On", params.get("host", SNMP_DEFAULT_HOST), SNMP_BASE_OID
    ], mutates=False)
    
    # Parse the snmpget output: "<OID> = <TYPE>: <value>"
    out = res.stdout.strip()
    if out == "":
        return {"changed": False, "msg": "no SNMP response for transactions",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract value after ": "
    idx = out.find(": ")
    if idx == -1:
        return {"changed": False, "msg": "unexpected SNMP output format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val_str = out[idx + 2:].strip()
    
    # Extract numeric part (remove trailing text like "Gauge32:")
    parts = val_str.split()
    if len(parts) == 0:
        return {"changed": False, "msg": "invalid transaction value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract numeric part: take the last word and strip non-digits
    last_part = parts[-1].strip()
    # Keep only leading digits
    digits = ""
    for c in last_part:
        if c.isdigit():
            digits += c
        else:
            break
    
    if digits == "":
        return {"changed": False, "msg": "invalid transaction value: " + val_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    transactions = int(digits)
    
    # Apply levels (upper levels: WARN if >= warn, CRIT if >= crit)
    warn, crit = params.get("levels", DEFAULT_LEVELS)
    
    if transactions >= crit:
        state = "CRIT"
    elif transactions >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "Transactions per minute (avg): %d" % transactions,
        "data": {
            "state": state,
            "metrics": {"transactions": transactions},
            "details": ""
        }
    }
