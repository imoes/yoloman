# Top-level constants — no Python imports, no re, no class/while/lambda/f-strings

# Default filesystem levels from Checkmk's df plugin
FILESYSTEM_DEFAULT_PARAMS = {
    "levels": (80.0, 90.0),
    "magic_normsize": 20.0,
    "levels_low": (50.0, 60.0),
    "trend_range": 24,
    "trend_showtimeleft": True,
    "trend_perfdata": True,
    "show_levels": "onmap",
    "show_reserved": True,
}

def _parse_span(string_table):
    section = {}
    for row in string_table:
        if len(row) < 6:
            continue
        id_ = row[0]
        label = row[1]
        total_upper_str = row[2]
        total_lower_str = row[3]
        used_upper_str = row[4]
        used_lower_str = row[5]
        
        # Guard instead of try/except — only convert if numeric
        if not (total_upper_str.isdigit() and total_lower_str.isdigit() and used_upper_str.isdigit() and used_lower_str.isdigit()):
            continue
        total_upper = int(total_upper_str)
        total_lower = int(total_lower_str)
        used_upper = int(used_upper_str)
        used_lower = int(used_lower_str)
        
        item = str(id_) + " " + str(label)
        size_mb = (total_upper * 4294967296 + total_lower) / 1048576.0
        used_mb = (used_upper * 4294967296 + used_lower) / 1048576.0
        avail_mb = size_mb - used_mb
        # (item, size_mb, avail_mb, 0.0) — last field is always 0.0 in source
        section[item] = (item, size_mb, avail_mb, 0.0)
    return section

def _df_check_filesystem_list(value_store, item, params, fslist_blocks):
    # Reproduce the logic of cmk.plugins.lib.df.df_check_filesystem_list
    # for a single-item list (fslist_blocks has exactly one tuple: (item, size_mb, avail_mb, 0.0))
    if len(fslist_blocks) == 0:
        return {"state": "UNKNOWN", "msg": "item not found", "metrics": {}, "details": ""}
    
    fs = fslist_blocks[0]
    if len(fs) < 4:
        return {"state": "UNKNOWN", "msg": "invalid block format", "metrics": {}, "details": ""}
    
    _, size_mb, avail_mb, _ = fs
    used_mb = size_mb - avail_mb
    
    # Extract levels
    levels = params.get("levels", FILESYSTEM_DEFAULT_PARAMS["levels"])
    warn_pct = levels[0]
    crit_pct = levels[1]
    
    # Compute percentages (avoid division by zero)
    if size_mb > 0:
        used_pct = (used_mb / size_mb) * 100.0
    else:
        used_pct = 0.0
    
    # Determine state (upper bounds)
    state = "OK"
    if used_pct >= crit_pct:
        state = "CRIT"
    elif used_pct >= warn_pct:
        state = "WARN"
    
    # Build human-readable message (Checkmk-style)
    # Size: X MB, Used: Y MB, Avail: Z MB, Usage: P%
    msg = "Size: %f MB, Used: %f MB, Avail: %f MB, Usage: %f%%" % (size_mb, used_mb, avail_mb, used_pct)
    
    return {
        "state": state,
        "msg": msg,
        "metrics": {
            "size": size_mb,
            "used": used_mb,
            "avail": avail_mb,
            "util": used_pct,
        },
        "details": "",
    }

def _df_discovery(params, section_list):
    # Reproduce df_discovery from cmk.plugins.lib.df
    # For hitachi_hnas_span, section is a dict of item -> (item, size_mb, avail_mb, 0.0)
    groups = params.get("groups", [])
    if not groups:
        # No grouping: each item is its own group
        return [{"item": item, "params": {"levels": FILESYSTEM_DEFAULT_PARAMS["levels"]}, "metrics": ["util"]} for item in section_list]
    # Grouping not supported here — source uses groups=[] by default for this plugin
    return []

def main(ctx, params):
    if params.get("_discover"):
        # SNMP walk for hitachi_hnas_span section
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.11096.6.1.1.6.4.2.1"
        # Build full OIDs (base + .1, .2, ... .6)
        oids = [base_oid + "." + str(i) for i in range(1, 7)]
        # snmpwalk -v2c -c <community> -On <host> <oid1> <oid2> ...
        argv = ["snmpwalk", "-v2c", "-c", community, "-On", host] + oids
        res = ctx.run(argv, mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        # Parse snmpwalk lines: "<oid> = <type>: <value>"
        # Since we fetched multiple OIDs, output is interleaved. Group by position.
        # snmpwalk output format: ".1.3.6.1.4.1.11096.6.1.1.6.4.2.1.1 = INTEGER: 1"
        # We'll collect raw values in order and group into rows of 6.
        lines = res.stdout.splitlines()
        values = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            # Find ": " separator
            idx = line.find(": ")
            if idx != -1:
                value = line[idx + 2:].strip()
                values.append(value)
        # Group values into rows of 6 (one per span)
        rows = []
        for i in range(0, len(values), 6):
            row = values[i:i+6]
            if len(row) == 6:
                rows.append(row)
        section = _parse_span(rows)
        discovery = _df_discovery(params, list(section.keys()))
        return {"changed": False, "msg": "discovered %d spans" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Normal check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.11096.6.1.1.6.4.2.1"
    oids = [base_oid + "." + str(i) for i in range(1, 7)]
    argv = ["snmpwalk", "-v2c", "-c", community, "-On", host] + oids
    res = ctx.run(argv, mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse
    lines = res.stdout.splitlines()
    values = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        idx = line.find(": ")
        if idx != -1:
            values.append(line[idx+2:].strip())
    
    # Group into rows of 6
    rows = []
    for i in range(0, len(values), 6):
        row = values[i:i+6]
        if len(row) == 6:
            rows.append(row)
    section = _parse_span(rows)
    
    # Build fslist by filtering for requested item
    fslist = []
    for k, v in section.items():
        if k == item:
            fslist.append(v)
            break
    
    if len(fslist) == 0:
        return {"changed": False, "msg": "span item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Apply df_check_filesystem_list logic
    result = _df_check_filesystem_list(None, item, params, fslist)
    return {"changed": False, "msg": result["msg"],
            "data": {
                "state": result["state"],
                "metrics": result["metrics"],
                "details": result["details"],
            }}