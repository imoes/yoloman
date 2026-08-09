# Constants for status mapping
_STATUSMAP = ("ok", "attn", "down", "invalid")

def main(ctx, params):
    # Discovery mode: always discover exactly one service
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: fetch SNMP data for node health section
    # Base OID for node health: .1.3.6.1.4.1.12124.2.1
    base_oid = ".1.3.6.1.4.1.12124.2.1"
    
    # Fetch both OIDs (1=nodeName, 2=nodeHealthStatus)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), 
        "-On", params.get("host", "localhost"), base_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse SNMP output: look for lines with our OIDs
    nodename = ""
    status = -1
    
    for line in res.stdout.splitlines():
        stripped = line.strip()
        # Split OID and value
        parts = stripped.split(" = ", 1)
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract value type and actual value
        if ":" in value_part:
            value_type, val = value_part.split(":", 1)
            val = val.strip()
        else:
            val = value_part
        
        # Node name OID: .1.3.6.1.4.1.12124.2.1.1
        if oid_part.endswith(".1"):
            nodename = val
        # Node health status OID: .1.3.6.1.4.1.12124.2.1.2
        elif oid_part.endswith(".2"):
            if val.isdigit():
                status = int(val)

    # Validate we got data
    if status < 0 or nodename == "":
        return {
            "changed": False,
            "msg": "Node health data not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Determine state
    if status >= len(_STATUSMAP):
        state = "UNKNOWN"
        summary = "nodeHealth reports unidentified status %d" % status
    else:
        state = "OK" if status == 0 else "CRIT"
        summary = "nodeHealth for %s reports status %s" % (nodename, _STATUSMAP[status])

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
