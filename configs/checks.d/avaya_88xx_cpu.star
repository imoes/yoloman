# ===== Starlark translation of checkmk.avaya_88xx_cpu =====
# Read-only: only gathers SNMP data and reports CPU utilization state

DETECT_AVAYA_OID = ".1.3.6.1.2.1.1.2.0"
AVAYA_ENTERPRISE_OID = ".1.3.6.1.4.1.2272"
CPU_OID_BASE = ".1.3.6.1.4.1.2272.1.1"
CPU_OID = ".1.3.6.1.4.1.2272.1.1.20"

def main(ctx, params):
    # Discovery mode: yield single-service entry
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {"util": (90.0, 95.0)}, "metrics": ["util"]}]},
        }

    # Check mode: get CPU utilization via SNMP
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # First, verify this is an Avaya device (to avoid false positives)
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, DETECT_AVAYA_OID], mutates=False)
    if res.rc != 0 or AVAYA_ENTERPRISE_OID not in res.stdout:
        return {
            "changed": False,
            "msg": "not an Avaya device or SNMP error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Get CPU utilization OID
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, CPU_OID], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP get failed or empty response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse value: expect format ".1.3.6.1.4.1.2272.1.1.20 = INTEGER: 23"
    line = res.stdout.strip()
    if "INTEGER:" not in line:
        return {
            "changed": False,
            "msg": "unable to parse CPU value from SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    parts = line.split("INTEGER:")
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "malformed SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    util_str = parts[1].strip()
    if not util_str.isdigit():
        return {
            "changed": False,
            "msg": "CPU value is not an integer",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    util = int(util_str)
    
    # Apply thresholds (Checkmk defaults: warn 90.0%, crit 95.0%)
    warn = 90.0
    crit = 95.0
    
    # Checkmk CPU util: warn/crit are upper bounds (>= triggers state change)
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "CPU: %d%%" % util,
        "data": {"state": state, "metrics": {"util": util}, "details": ""},
    }
