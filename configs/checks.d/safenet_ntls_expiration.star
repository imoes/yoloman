# Helper to parse the SNMP table row (single list of 6 strings)
# operation_status, connected_clients, links, successful_connections, failed_connections, expiration_date

def _parse_section(row):
    if row == None or len(row) != 6:
        return None
    # Guard each conversion safely - Starlark has no try/except
    def safe_int(s):
        s = s.strip()
        if s == "" or not (s.isdigit() or (s.startswith("-") and s[1:].isdigit() and len(s) > 1)):
            return 0
        return int(s)
    
    return {
        "operation_status": row[0],
        "connected_clients": safe_int(row[1]),
        "links": safe_int(row[2]),
        "successful_connections": safe_int(row[3]),
        "failed_connections": safe_int(row[4]),
        "expiration_date": row[5],
    }

def main(ctx, params):
    # Discovery mode: enumerate items
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.12383.3.1.2"
        ], mutates=False)
        # We only care if there's at least one row; discovery yields exactly one service
        # Since this is a single-service check (no per-item breakdown), return one item with ""
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # Minimal heuristic: look for the key OID prefix to confirm NTLS section
        if ".1.3.6.1.4.1.12383.3.1.2" not in res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    
    # Check mode for the single-service NTLS Expiration Date check
    # Gather raw SNMP data
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.12383.3.1.2"
    ], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "Unable to fetch SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse: find first row matching our section prefix
    lines = res.stdout.splitlines()
    row = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(".1.3.6.1.4.1.12383.3.1.2."):
            # Extract value after '='
            idx = stripped.find("=")
            if idx != -1:
                val = stripped[idx+1:].strip()
                row.append(val)
            if len(row) == 6:
                break
    if len(row) < 6:
        return {"changed": False, "msg": "Incomplete SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = _parse_section(row)
    if section == None:
        return {"changed": False, "msg": "Failed to parse SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    exp = section["expiration_date"]
    if exp == "" or exp == "0":
        return {"changed": False, "msg": "Expiration date unknown",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Checkmk-style summary: "The NTLS server certificate expires on ..."
    return {"changed": False, "msg": "The NTLS server certificate expires on " + exp,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
