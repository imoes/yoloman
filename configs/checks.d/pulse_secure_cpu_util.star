# Top-level constants (no re, no imports, no classes)
CPU_OID = ".1.3.6.1.4.1.12532.10"
SERVICE_NAME = "Pulse Secure IVE CPU utilization"
DEFAULT_WARN = 80.0
DEFAULT_CRIT = 90.0

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: check if CPU OID is present by performing a lightweight snmpwalk
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), CPU_OID], mutates=False)
        # If the output contains at least one line with our OID, yield one service
        if res.rc != 0 or res.stdout.find(CPU_OID) == -1:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {"util": (DEFAULT_WARN, DEFAULT_CRIT)},
                                         "metrics": ["util"]}]}}
    
    # Check mode: fetch CPU utilization once
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Perform single OID get (snmpget) for the CPU OID
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, CPU_OID], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse output: expected format "OID = INTEGER: <value>"
    line = res.stdout.strip()
    parts = line.split(" = ")
    if len(parts) != 2 or parts[0].strip() != CPU_OID:
        return {"changed": False, "msg": "unexpected SNMP output format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_str = parts[1].strip()
    # Extract numeric value from "INTEGER: 123" or "INTEGER 123"
    colon_idx = value_str.find(":")
    if colon_idx != -1:
        value_str = value_str[colon_idx + 1:].strip()
    
    # Check for non-digit characters
    if not value_str.isdigit():
        return {"changed": False, "msg": "CPU utilization is not a valid integer",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    util = float(value_str)
    
    # Apply thresholds
    warn, crit = params.get("util", (DEFAULT_WARN, DEFAULT_CRIT))
    
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "CPU utilization: %f%%" % util
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"util": util}, "details": ""}}