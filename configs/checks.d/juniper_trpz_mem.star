# ===== module-level constants =====
JUNIPER_TRPZ_OID_BASE = ".1.3.6.1.4.1.14525.4.8.1.1"
JUNIPER_TRPZ_OID_USED = JUNIPER_TRPZ_OID_BASE + ".12.1"
JUNIPER_TRPZ_OID_TOTAL = JUNIPER_TRPZ_OID_BASE + ".6"

JUNIPER_SCREENOS_OID_BASE = ".1.3.6.1.4.1.3224.16.2"
JUNIPER_SCREENOS_OID_USED = JUNIPER_SCREENOS_OID_BASE + ".1.0"
JUNIPER_SCREENOS_OID_FREE = JUNIPER_SCREENOS_OID_BASE + ".2.0"

def _extract_value(line):
    if line == None or line.strip() == "":
        return None
    parts = line.split(" = ")
    if len(parts) != 2:
        return None
    value_part = parts[1].strip()
    # Extract numeric value after colon
    if value_part.startswith("STRING: ") or value_part.startswith("INTEGER: "):
        value_part = value_part.split(": ", 1)[1].strip().strip('"')
    if value_part.isdigit():
        return int(value_part)
    return None


def _parse_snmp_section(ctx, host, community, section_type):
    oid_used = ""
    oid_total = ""
    if section_type == "trpz":
        oid_used = JUNIPER_TRPZ_OID_USED
        oid_total = JUNIPER_TRPZ_OID_TOTAL
    elif section_type == "screenos":
        oid_used = JUNIPER_SCREENOS_OID_USED
    else:
        return None
    
    # Get used
    res_used = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, oid_used
    ], mutates=False)
    used = None
    if res_used.rc == 0 and res_used.stdout != None and res_used.stdout.strip() != "":
        used = _extract_value(res_used.stdout.strip())
    
    if section_type == "trpz":
        # Get total
        res_total = ctx.run([
            "snmpget", "-v2c", "-c", community, "-On", host, oid_total
        ], mutates=False)
        total = None
        if res_total.rc == 0 and res_total.stdout != None and res_total.stdout.strip() != "":
            total = _extract_value(res_total.stdout.strip())
        if used != None and total != None:
            return {"used": used * 1024, "total": total * 1024}
    else:  # screenos
        # Get free
        res_free = ctx.run([
            "snmpget", "-v2c", "-c", community, "-On", host, JUNIPER_SCREENOS_OID_FREE
        ], mutates=False)
        free = None
        if res_free.rc == 0 and res_free.stdout != None and res_free.stdout.strip() != "":
            free = _extract_value(res_free.stdout.strip())
        if used != None and free != None:
            return {"used": used, "total": used + free}
    return None


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        # Try TRPZ first, then ScreenOS
        section = _parse_snmp_section(ctx, host, community, "trpz")
        if section == None:
            section = _parse_snmp_section(ctx, host, community, "screenos")
        if section != None:
            return {
                "changed": False,
                "msg": "discovered 1 memory section",
                "data": {"discovery": [{"item": "", "params": {"levels": ("perc_used", (80.0, 90.0))}, "metrics": ["mem_used"]}]},
            }
        return {
            "changed": False,
            "msg": "no memory section discovered",
            "data": {"discovery": []},
        }
    
    # Check mode - one item only, item must be "" (single-service)
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Detect device type by querying sysObjectID
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to get sysObjectID: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    line = res.stdout.strip()
    if line == "":
        return {
            "changed": False,
            "msg": "empty sysObjectID response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    parts = line.split(" = ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "could not parse sysObjectID",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    sys_object = parts[1].strip()
    if not sys_object.startswith(".1.3.6.1.4.1."):
        return {
            "changed": False,
            "msg": "not a valid OID value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Determine section type
    section_type = None
    if sys_object.startswith(".1.3.6.1.4.1.2636.1.1.1."):
        if sys_object.startswith(".1.3.6.1.4.1.14525.3"):
            section_type = "trpz"
        elif sys_object.startswith(".1.3.6.1.4.1.3224.1"):
            section_type = "screenos"
        else:
            section_type = "trpz"  # Default to TRPZ
    else:
        return {
            "changed": False,
            "msg": "not a supported Juniper device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    section = _parse_snmp_section(ctx, host, community, section_type)
    if section == None:
        return {
            "changed": False,
            "msg": "failed to get memory data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Extract levels from params
    levels_tuple = params.get("levels", ("perc_used", (80.0, 90.0)))
    if levels_tuple == None:
        levels_tuple = ("perc_used", (80.0, 90.0))
    if type(levels_tuple) == "list":
        levels_tuple = tuple(levels_tuple)
    levels_type = levels_tuple[0]
    if levels_type != "perc_used":
        return {
            "changed": False,
            "msg": "unsupported levels type: " + str(levels_type),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    warn = levels_tuple[1][0]
    crit = levels_tuple[1][1]
    
    # Calculate percentages
    total = float(section["total"])
    used = float(section["used"])
    if total <= 0.0:
        return {
            "changed": False,
            "msg": "total memory is zero",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    used_percent = (used / total) * 100.0
    
    # Determine state
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message
    # Convert bytes to human-readable
    if used >= 1024.0 * 1024 * 1024:
        used_str = "%f GB" % (used / (1024.0 * 1024 * 1024))
    elif used >= 1024.0 * 1024:
        used_str = "%f MB" % (used / (1024.0 * 1024))
    else:
        used_str = "%f kB" % (used / 1024.0)
    msg = "Used: %s (%f%%)" % (used_str, used_percent)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"mem_used": used_percent},
            "details": "",
        },
    }