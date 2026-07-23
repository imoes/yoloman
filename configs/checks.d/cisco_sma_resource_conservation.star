# Map SNMP values to status strings
RESOURCE_CONSERVATION_MAP = {
    1: ("Resource conservation mode off", "OK"),
    2: ("Resource conservation mode on (memory shortage)", "WARN"),
    3: ("Resource conservation mode on (queue space shortage)", "WARN"),
    4: ("Resource conservation mode on (queue full)", "CRIT"),
}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: always yield one service
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }
    
    # Check mode: fetch SNMP data
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # OID .1.3.6.1.4.1.15497.1.1.1.6
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.15497.1.1.1.6"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output: expect format ".1.3.6.1.4.1.15497.1.1.1.6 = INTEGER: <value>"
    value = None
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(".1.3.6.1.4.1.15497.1.1.1.6") and "INTEGER:" in stripped:
            parts = stripped.split("INTEGER:")
            if len(parts) == 2:
                val_str = parts[1].strip()
                if val_str.isdigit():
                    value = int(val_str)
                    break
    
    # Determine state and message
    summary = "Resource conservation status unknown"
    state = "UNKNOWN"
    
    if value != None and value in RESOURCE_CONSERVATION_MAP:
        summary, state = RESOURCE_CONSERVATION_MAP[value]
    
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
