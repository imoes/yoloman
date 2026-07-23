# Module-level constants for SNMP OID and defaults
SNMP_BASE_OID = ".1.3.6.1.4.1.15497.1.1.1"
SNMP_THREAD_OID = SNMP_BASE_OID + ".20"
DEFAULT_WARN = 500
DEFAULT_CRIT = 1000

def main(ctx, params):
    # Discovery mode: always yield one service with no per-item items
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {
                    "levels_upper_total_threads": ("fixed", (DEFAULT_WARN, DEFAULT_CRIT)),
                    "levels_lower_total_threads": ("no_levels", None)
                }, "metrics": ["cisco_sma_mail_transfer_threads"]}
            ]}
        }

    # Check mode: gather thread count via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, SNMP_THREAD_OID
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP response: expected format "OID = INTEGER: <value>"
    line = res.stdout.strip()
    if not line or line.find("=") == -1:
        return {
            "changed": False,
            "msg": "malformed SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value_str = line.rsplit(":", 1)[-1].strip()
    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "non-numeric thread count",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    threads = int(value_str)
    
    # Extract levels from params (handle Checkmk tuple format)
    levels_upper = params.get("levels_upper_total_threads", ("fixed", (DEFAULT_WARN, DEFAULT_CRIT)))
    levels_lower = params.get("levels_lower_total_threads", ("no_levels", None))

    # Extract warn/crit from upper tuple format: ("fixed", (warn, crit))
    warn = None
    crit = None
    if levels_upper[0] == "fixed":
        warn, crit = levels_upper[1]
    
    # Determine state based on upper levels only (lower levels not implemented in source)
    state = "OK"
    if crit != None and threads >= crit:
        state = "CRIT"
    elif warn != None and threads >= warn:
        state = "WARN"
    
    # Checkmk-style message
    msg = "Total: %d" % threads
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"cisco_sma_mail_transfer_threads": threads},
            "details": ""
        }
    }
