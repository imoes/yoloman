def main(ctx, params):
    if params.get("_discover"):
        # Discovery: single-service check for memory system
        return {
            "changed": False,
            "msg": "discovered 1 memory system",
            "data": {"discovery": [{"item": "", "params": {"levels": ("perc_used", (80.0, 90.0))}, "metrics": ["memory_used"]}]},
        }

    # Check mode: get memory usage via SNMP
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # FETCH .1.3.6.1.4.1.2620.1.6.7.4.3.0 (memTotalReal) and .1.3.6.1.4.1.2620.1.6.7.4.4.0 (memAvailReal)
    # Use snmpwalk with base OID and specific sub-OID
    base_oid = ".1.3.6.1.4.1.2620.1.6.7.4"
    total_oid = base_oid + ".3.0"
    avail_oid = base_oid + ".4.0"
    
    # Walk both OIDs separately (snmpwalk returns one line per OID)
    res_total = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, total_oid], mutates=False)
    res_avail = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, avail_oid], mutates=False)
    
    # Parse total memory
    mem_total_bytes = None
    for line in res_total.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Format: OID = INTEGER: value
        if ": INTEGER: " in line:
            parts = line.split(": INTEGER: ", 1)
            if len(parts) == 2 and parts[1].strip().isdigit():
                mem_total_bytes = int(parts[1].strip())
                break
    
    # Parse available memory
    mem_avail_bytes = None
    for line in res_avail.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if ": INTEGER: " in line:
            parts = line.split(": INTEGER: ", 1)
            if len(parts) == 2 and parts[1].strip().isdigit():
                mem_avail_bytes = int(parts[1].strip())
                break
    
    # Check data availability
    if mem_total_bytes == None or mem_avail_bytes == None:
        return {
            "changed": False,
            "msg": "Unable to retrieve memory data via SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Calculate used memory
    mem_used_bytes = mem_total_bytes - mem_avail_bytes
    
    # Get levels from params (Checkmk default: ("perc_used", (80.0, 90.0)))
    levels_tuple = params.get("levels", ("perc_used", (80.0, 90.0)))
    if not isinstance(levels_tuple, (list, tuple)) or len(levels_tuple) != 2:
        return {
            "changed": False,
            "msg": "Invalid levels format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    levels_type = levels_tuple[0]
    if levels_type != "perc_used":
        return {
            "changed": False,
            "msg": "Unsupported levels type: " + str(levels_type),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    warn_percent, crit_percent = levels_tuple[1]
    if not isinstance(warn_percent, (int, float)) or not isinstance(crit_percent, (int, float)):
        return {
            "changed": False,
            "msg": "Invalid level values",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Calculate usage percentage
    if mem_total_bytes == 0:
        usage_percent = 0.0
    else:
        usage_percent = (mem_used_bytes * 100.0) / mem_total_bytes
    
    # Determine state
    if usage_percent >= crit_percent:
        state = "CRIT"
    elif usage_percent >= warn_percent:
        state = "WARN"
    else:
        state = "OK"
    
    # Format summary message
    # Convert bytes to human-readable units
    def format_bytes(b):
        for unit in ["B", "KB", "MB", "GB", "TB"]:
            if abs(b) < 1024.0:
                return "%f %s" % (b, unit)
            b /= 1024.0
        return "%f %s" % (b, "PB")
    
    msg = "Usage: %f%%, Total: %s, Used: %s" % (
        usage_percent,
        format_bytes(mem_total_bytes),
        format_bytes(mem_used_bytes),
    )
    
    # Return check result
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"memory_used": mem_used_bytes},
            "details": "",
        },
    }
