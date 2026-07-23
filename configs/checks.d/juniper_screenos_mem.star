# ===== Starlark check module: juniper_screenos_mem =====


# Module-level constants for SNMP OIDs
JUNIPER_SCREENOS_MEM_BASE = ".1.3.6.1.4.1.3224.16.2"
JUNIPER_SCREENOS_MEM_USED_OID = JUNIPER_SCREENOS_MEM_BASE + ".1.0"
JUNIPER_SCREENOS_MEM_FREE_OID = JUNIPER_SCREENOS_MEM_BASE + ".2.0"

# Checkmk defaults for memory thresholds
DEFAULT_LEVELS_TYPE = "perc_used"
DEFAULT_WARN = 80.0
DEFAULT_CRIT = 90.0


def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        # Single-service check: one Service() entry
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "levels": ("perc_used", (DEFAULT_WARN, DEFAULT_CRIT))
                        },
                        "metrics": ["mem_used_percent"]
                    }
                ]
            },
        }

    # ===== CHECK MODE =====
    # Read parameters (item always "" for single-service check)
    item = params.get("item", "")
    levels_spec = params.get("levels", (DEFAULT_LEVELS_TYPE, (DEFAULT_WARN, DEFAULT_CRIT)))
    
    # Only "perc_used" level type is supported in the original
    levels_type = levels_spec[0] if isinstance(levels_spec, list) else levels_spec
    warn, crit = levels_spec[1] if len(levels_spec) > 1 else (DEFAULT_WARN, DEFAULT_CRIT)
    
    # Check for unsupported level type
    if levels_type != "perc_used":
        return {
            "changed": False,
            "msg": "Unsupported levels type '%s' - only 'perc_used' is supported" % levels_type,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Run SNMP walk for the two OIDs
    used_oid = JUNIPER_SCREENOS_MEM_USED_OID
    free_oid = JUNIPER_SCREENOS_MEM_FREE_OID
    
    # Try to get both values via snmpget (single OID at a time)
    res_used = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        used_oid
    ], mutates=False)
    
    res_free = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        free_oid
    ], mutates=False)

    # Parse outputs: format is "OID = STRING: value"
    def extract_snmp_value(res):
        if res.rc != 0:
            return None
        lines = res.stdout.strip().splitlines()
        if len(lines) != 1:
            return None
        line = lines[0]
        # Split at the first '='
        if '=' not in line:
            return None
        parts = line.split('=', 1)
        if len(parts) != 2:
            return None
        value_str = parts[1].strip()
        # Remove trailing space and quotes if present
        value_str = value_str.strip()
        # Extract the numeric value from type: value format
        if ':' in value_str:
            value_str = value_str.split(':', 1)[1].strip()
        # Remove quotes if present
        if value_str.startswith('"') and value_str.endswith('"'):
            value_str = value_str[1:-1]
        return value_str.strip()

    used_str = extract_snmp_value(res_used)
    free_str = extract_snmp_value(res_free)

    # Validate values
    if used_str == None or used_str == "" or not used_str.isdigit():
        return {
            "changed": False,
            "msg": "Could not retrieve memory usage (used OID: %s)" % used_oid,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if free_str == None or free_str == "" or not free_str.isdigit():
        return {
            "changed": False,
            "msg": "Could not retrieve memory usage (free OID: %s)" % free_oid,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    used = int(used_str)
    free = int(free_str)
    total = used + free

    if total == 0:
        return {
            "changed": False,
            "msg": "Memory total is zero",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Compute percentage
    used_percent = float(used * 100) / float(total)

    # Determine state
    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"

    # Format message
    msg = "Used: %f%%" % used_percent

    # Return result
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"mem_used_percent": used_percent},
            "details": ""
        },
    }