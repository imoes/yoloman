# Module-level constants
SNMP_BASE = ".1.3.6.1.4.1.15497.1.1.1"
SNMP_OID_FILES_AND_SOCKETS = ".19"

# Checkmk default parameters
DEFAULT_LEVELS_UPPER = ("fixed", (5500, 6000))
DEFAULT_LEVELS_LOWER = ("no_levels", None)

def _parse_files_and_sockets(value_str):
    if value_str == None or value_str == "" or not value_str.strip().isdigit():
        return None
    return int(value_str.strip())

def _check_levels(value, levels_upper, levels_lower):
    # levels_upper: ("fixed", (warn, crit)) or ("no_levels", None)
    # levels_lower: ("fixed", (warn, crit)) or ("no_levels", None)
    state = "OK"
    details = ""
    
    # Upper levels
    if levels_upper[0] == "fixed":
        warn, crit = levels_upper[1]
        if value >= crit:
            state = "CRIT"
            details = " (warn=%d, crit=%d)" % (warn, crit)
        elif value >= warn:
            state = "WARN"
            details = " (warn=%d, crit=%d)" % (warn, crit)
    
    # Lower levels
    if state == "OK" and levels_lower[0] == "fixed":
        warn, crit = levels_lower[1]
        if value <= crit:
            state = "CRIT"
            details = " (warn=%d, crit=%d)" % (warn, crit)
        elif value <= warn:
            state = "WARN"
            details = " (warn=%d, crit=%d)" % (warn, crit)
    
    return state, details

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["cisco_sma_files_and_sockets"]}]}
        }
    
    # Check mode
    item = params.get("item", "")
    
    # Get SNMP parameters
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Probe SNMP for files and sockets count
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, SNMP_BASE + SNMP_OID_FILES_AND_SOCKETS], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse SNMP output: lines like "OID = INTEGER: value"
    value = None
    for line in res.stdout.splitlines():
        if line.find(SNMP_OID_FILES_AND_SOCKETS) != -1:
            # Extract the value after " = INTEGER: "
            idx = line.find(" = INTEGER: ")
            if idx != -1:
                val_str = line[idx + len(" = INTEGER: "):].strip()
                value = _parse_files_and_sockets(val_str)
                break
    
    # If value could not be parsed
    if value == None:
        return {
            "changed": False,
            "msg": "could not parse SNMP value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get thresholds from params or defaults
    levels_upper = params.get("levels_upper_open_files_and_sockets", DEFAULT_LEVELS_UPPER)
    levels_lower = params.get("levels_lower_open_files_and_sockets", DEFAULT_LEVELS_LOWER)
    
    state, details = _check_levels(value, levels_upper, levels_lower)
    msg = "Open: %d" % value + details
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"cisco_sma_files_and_sockets": value},
            "details": ""
        },
    }
