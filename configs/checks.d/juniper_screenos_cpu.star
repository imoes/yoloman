# Module-level constants for SNMP OIDs
JUNIPER_SCREENOS_CPU_BASE_OID = ".1.3.6.1.4.1.3224.16.1"
JUNIPER_SCREENOS_OID_UTIL1 = "2"
JUNIPER_SCREENOS_OID_UTIL15 = "4"

# Default thresholds from Checkmk plugin
DEFAULT_UTIL_WARN = 80.0
DEFAULT_UTIL_CRIT = 90.0


def _get_snmp_value(ctx, host, community, oid):
    """Fetch a single SNMP OID value using snmpget."""
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, oid
    ], mutates=False)
    
    if res.rc != 0:
        return None
    
    # Parse snmpget output: "<oid> = <type>: <value>"
    line = res.stdout.strip()
    if not line or line.find(" = ") == -1:
        return None
    
    # Extract value part after " = "
    value_part = line.split(" = ", 1)[1].strip()
    # Extract numeric value (e.g., "Gauge32: 25.4" -> "25.4")
    if ":" in value_part:
        value_str = value_part.split(":", 1)[1].strip()
    else:
        value_str = value_part
    
    # Guard: only convert if value_str looks like a number
    clean_str = value_str.rstrip("%").strip()
    if clean_str == "":
        return None
    
    # Check if it's a valid number (integer or float)
    is_float = False
    for c in clean_str:
        if c == '.':
            is_float = True
            break
    
    if is_float:
        parts = clean_str.split(".")
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            return float(clean_str)
        else:
            return None
    else:
        if clean_str.isdigit():
            return float(clean_str)
        else:
            return None


def main(ctx, params):
    # Get SNMP connection parameters from params or use defaults
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Fetch CPU utilization values from SNMP
    util1 = _get_snmp_value(ctx, host, community, JUNIPER_SCREENOS_CPU_BASE_OID + "." + JUNIPER_SCREENOS_OID_UTIL1)
    util15 = _get_snmp_value(ctx, host, community, JUNIPER_SCREENOS_CPU_BASE_OID + "." + JUNIPER_SCREENOS_OID_UTIL15)
    
    # Check if we got valid data
    if util1 == None or util15 == None:
        return {
            "changed": False,
            "msg": "Unable to retrieve CPU utilization values from SNMP",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Handle discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "util": [DEFAULT_UTIL_WARN, DEFAULT_UTIL_CRIT]
                        },
                        "metrics": ["util1", "util15"]
                    }
                ]
            }
        }
    
    # Normal check mode
    item = params.get("item", "")
    if item != "":
        # This check only supports single-service (item=""), but we handle any item gracefully
        return {
            "changed": False,
            "msg": "CPU utilization (single-service check only)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "This check only supports item ''"
            }
        }
    
    # Extract threshold parameters
    # Checkmk stores thresholds as tuple in params.get("util") or as dict
    util_levels = params.get("util", [DEFAULT_UTIL_WARN, DEFAULT_UTIL_CRIT])
    if type(util_levels) == "list" and len(util_levels) == 2:
        warn_val = float(util_levels[0])
        crit_val = float(util_levels[1])
    else:
        # Fallback to defaults
        warn_val = DEFAULT_UTIL_WARN
        crit_val = DEFAULT_UTIL_CRIT
    
    # Determine state based on thresholds (upper levels)
    # util1 is always OK since no levels provided for 1-minute (per source)
    # util15 uses levels
    state_util1 = "OK"
    state_util15 = "CRIT" if util15 >= crit_val else ("WARN" if util15 >= warn_val else "OK")
    
    # Overall state: CRIT if any component is CRIT, else WARN if any is WARN, else OK
    state = state_util15  # util1 has no levels in source, so overall state depends on util15
    
    # Build message
    msg = "CPU utilization: 1min %s%%, 15min %s%%" % (int(util1), int(util15))
    
    # Build metrics dict
    metrics = {
        "util1": util1,
        "util15": util15
    }
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }