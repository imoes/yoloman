# Module-level constants (maps and defaults)
# FILESYSTEM_DEFAULT_PARAMS from cmk.plugins.lib.df (simplified to Starlark dict)
FILESYSTEM_DEFAULT_PARAMS = {
    "levels": (80.0, 90.0),
    "levels_low": (50.0, 60.0),
    "magic_normsize": 100.0,
    "show_levels": "onwarn",
    "show_inodes": "onlow",
    "show_reserved": True,
    "total_size": None,
    "invert": False,
    "single_name": "",
}

# Discovery params: we ignore the groups param here (handled by Checkmk server side),
# but keep the same structure for params.get("groups", [])
DISCOVERY_DEFAULT_PARAMS = {"groups": []}

# Helper: parse SNMP line "OID = TYPE: value" -> (oid_str, value)
# We only need the last component after last dot for value extraction
def _parse_snmp_line(line):
    # Example: ".1.3.6.1.4.1.789.1.5.4.1.2.1.1.1.29 = Gauge32: 10485760"
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return None, None
    oid = parts[0].strip()
    value_part = parts[1].strip()
    # Remove type prefix: "Gauge32: ", "INTEGER: ", etc.
    colon_pos = value_part.find(":")
    if colon_pos != -1:
        value_str = value_part[colon_pos + 1:].strip()
    else:
        value_str = value_part
    return oid, value_str

# Helper: map OID suffix to field (we need "2", "29", "30" for v1 and "2", "3", "4" for v2)
def _extract_volume_info(volumes, sizes_kb, used_kb):
    # Return list of (name, size_kb, used_kb) tuples
    result = []
    for i in range(len(volumes)):
        name = volumes[i] if i < len(volumes) else ""
        size = sizes_kb[i] if i < len(sizes_kb) else ""
        used = used_kb[i] if i < len(used_kb) else ""
        if name and size and size.isdigit():
            result.append((name, size, used))
    return result

def main(ctx, params):
    # Determine mode: discovery or check
    if params.get("_discover"):
        # Use SNMP to gather NetApp filesystem data
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # Try the 64-bit version first (oids 2, 29, 30)
        res_v1 = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.789.1.5.4.1.2"
        ], mutates=False)
        
        res_v29 = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.789.1.5.4.1.29"
        ], mutates=False)

        res_v30 = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.789.1.5.4.1.30"
        ], mutates=False)

        if res_v1.rc != 0 or res_v29.rc != 0 or res_v30.rc != 0:
            # Try 32-bit version (oids 2, 3, 4) if 64-bit fails
            res_v1 = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On", host,
                ".1.3.6.1.4.1.789.1.5.4.1.2"
            ], mutates=False)

            res_v3 = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On", host,
                ".1.3.6.1.4.1.789.1.5.4.1.3"
            ], mutates=False)

            res_v4 = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On", host,
                ".1.3.6.1.4.1.789.1.5.4.1.4"
            ], mutates=False)
            
            if res_v1.rc != 0 or res_v3.rc != 0 or res_v4.rc != 0:
                return {
                    "changed": False,
                    "msg": "SNMP query failed",
                    "data": {"discovery": []}
                }

            volumes, sizes_kb, used_kb = [], [], []
            for line in res_v1.stdout.splitlines():
                oid, value = _parse_snmp_line(line)
                if value and value.isdigit():
                    volumes.append(value)
            
            for line in res_v3.stdout.splitlines():
                oid, value = _parse_snmp_line(line)
                if value and value.isdigit():
                    sizes_kb.append(value)
            
            for line in res_v4.stdout.splitlines():
                oid, value = _parse_snmp_line(line)
                if value and value.isdigit():
                    used_kb.append(value)

            info_list = _extract_volume_info(volumes, sizes_kb, used_kb)
        else:
            # Use 64-bit version
            volumes, sizes_kb, used_kb = [], [], []
            for line in res_v1.stdout.splitlines():
                oid, value = _parse_snmp_line(line)
                if value and value.isdigit():
                    volumes.append(value)
            
            for line in res_v29.stdout.splitlines():
                oid, value = _parse_snmp_line(line)
                if value and value.isdigit():
                    sizes_kb.append(value)
            
            for line in res_v30.stdout.splitlines():
                oid, value = _parse_snmp_line(line)
                if value and value.isdigit():
                    used_kb.append(value)

            info_list = _extract_volume_info(volumes, sizes_kb, used_kb)

        # Build discovery results (filter zero-size volumes)
        out = []
        for name, size_kb, used_kb in info_list:
            size_mb = float(size_kb) / 1024.0 if size_kb and size_kb.isdigit() else 0.0
            if size_mb > 0:
                out.append({
                    "item": name,
                    "params": {"levels": (80.0, 90.0), "levels_low": (50.0, 60.0)},
                    "metrics": ["used_percent"]
                })

        return {
            "changed": False,
            "msg": "discovered %d filesystems" % len(out),
            "data": {"discovery": out}
        }

    # Check mode (non-discovery)
    item = params.get("item", "")
    
    # Gather data via SNMP
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res_v1 = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.789.1.5.4.1.2"
    ], mutates=False)
    
    res_v29 = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.789.1.5.4.1.29"
    ], mutates=False)

    res_v30 = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.789.1.5.4.1.30"
    ], mutates=False)

    if res_v1.rc != 0 or res_v29.rc != 0 or res_v30.rc != 0:
        res_v1 = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.789.1.5.4.1.2"
        ], mutates=False)
        
        res_v3 = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.789.1.5.4.1.3"
        ], mutates=False)
        
        res_v4 = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.789.1.5.4.1.4"
        ], mutates=False)

        if res_v1.rc != 0 or res_v3.rc != 0 or res_v4.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
    else:
        res_v3 = res_v29
        res_v4 = res_v30

    # Parse all data
    volumes = {}
    for line in res_v1.stdout.splitlines():
        oid, value = _parse_snmp_line(line)
        if value:
            volumes[oid] = value

    sizes_kb = {}
    for line in res_v3.stdout.splitlines():
        oid, value = _parse_snmp_line(line)
        if value and value.isdigit():
            sizes_kb[oid] = value

    used_kb = {}
    for line in res_v4.stdout.splitlines():
        oid, value = _parse_snmp_line(line)
        if value and value.isdigit():
            used_kb[oid] = value

    # Find matching volume by item (match suffix after last dot)
    volume_name = ""
    item_suffix = "." + item if item else ""
    
    for oid, vol in volumes.items():
        if item == "" or (item_suffix and oid.endswith(item_suffix)) or vol == item:
            volume_name = vol
            break
    
    if not volume_name:
        for vol in volumes.values():
            if vol == item:
                volume_name = vol
                break
    
    # Find the size and used values
    size_kb = 0.0
    used_val = 0.0
    
    for oid, vol in volumes.items():
        if vol == volume_name:
            # Try 64-bit versions first
            if oid in sizes_kb:
                size_kb = float(sizes_kb[oid])
            elif oid in used_kb:
                used_val = float(used_kb[oid])
            
            # Look up matching size/used values by common prefix
            prefix = ".".join(oid.split(".")[:-1])
            for k, v in sizes_kb.items():
                if k.startswith(prefix) and k.endswith(".29") or k.endswith(".3"):
                    size_kb = float(v)
                    break
            
            for k, v in used_kb.items():
                if k.startswith(prefix) and k.endswith(".30") or k.endswith(".4"):
                    used_val = float(v)
                    break
    
    # Calculate percentages
    size_mb = size_kb / 1024.0 if size_kb else 0.0
    avail_mb = size_mb - (used_val / 1024.0) if size_mb and size_kb else 0.0
    used_percent = ((size_mb - avail_mb) / size_mb * 100.0) if size_mb > 0 else 0.0
    
    # Extract thresholds from params (use Checkmk defaults)
    warn, crit = params.get("levels", (80.0, 90.0))
    if type(warn) == "list":
        warn = warn[0]
        crit = crit[0]
    
    # Determine state
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message
    msg = "%s: %d%% used" % (item if item else "Filesystem", int(used_percent))
    
    # Return result
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent},
            "details": ""
        }
    }
