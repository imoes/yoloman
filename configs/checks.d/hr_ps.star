# hr_ps starlark check - read-only SNMP-based process monitor

_HR_PS_STATUS_MAP = {
    "1": ("running", "running", ""),
    "2": ("runnable", "runnable", "waiting for resource"),
    "3": ("not_runnable", "not runnable", "loaded but waiting for event"),
    "4": ("invalid", "invalid", "not loaded"),
}

def _parse_hr_ps(string_table):
    parsed = []
    for entry in string_table:
        if len(entry) < 3:
            continue
        name, path, status = entry[0].strip(":"), entry[1], entry[2]
        key, short, long_ = _HR_PS_STATUS_MAP.get(status, (status, "unknown[%s]" % status, ""))
        parsed.append({"name": name, "path": path, "state_key": key, "state_short": short, "state_long": long_})
    return parsed

def _match_process(proc, match_name_or_path, match_status, match_groups):
    if match_status != None:
        if proc["state_key"] not in match_status:
            return False
    
    if match_name_or_path == None or match_name_or_path == "match_all":
        return True
    
    match_type = match_name_or_path[0]
    match_pattern = match_name_or_path[1]
    pattern_to_match = proc["name"] if match_type == "match_name" else proc["path"]
    
    if match_pattern != None and match_pattern.startswith("~"):
        # Regex for complete process name or path
        # skip "~"
        pattern = match_pattern[1:]
        # Simple regex: only ^ and $ supported
        anchored = False
        if pattern.startswith("^") and pattern.endswith("$"):
            pattern = pattern[1:-1]
            anchored = True
        elif pattern.startswith("^"):
            pattern = pattern[1:]
        elif pattern.endswith("$"):
            pattern = pattern[:-1]
        
        if anchored:
            if pattern_to_match != pattern:
                return False
        else:
            if pattern not in pattern_to_match:
                return False
        
        # Extract groups if needed
        if match_groups != None:
            # Basic support: only simple cases where match_groups is []
            # For full regex match_groups support, we'd need a real regex engine
            # Since Starlark has no regex, we assume empty match_groups means "no groups expected"
            if match_groups != []:
                return False
        return True
    
    # Exact match
    return pattern_to_match == match_pattern

def _match_all_processes(section, item, params):
    match_name_or_path = params.get("match_name_or_path")
    match_status = params.get("match_status")
    match_groups = params.get("match_groups")
    
    matching = []
    for proc in section:
        if _match_process(proc, match_name_or_path, match_status, match_groups):
            matching.append(proc)
    return matching

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: enumerate services by matching rules
        # We simulate discovery rules using default discovery parameters
        default_params = params.get("discovery_default_parameters", {"descr": "%s", "default_params": {}})
        # Read rules from discovery_ruleset_name if available (simulated via discovery_params)
        # For simplicity: use single default discovery rule
        rules = params.get("discovery_rules", [])
        if len(rules) == 0:
            rules = [{"descr": "%s", "match_name_or_path": "match_all", "match_status": None}]
        
        # Get SNMP section data
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On", 
                       params.get("host", "localhost"), ".1.3.6.1.2.1.25.4.2.1"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        # Parse SNMP output: each line is "OID = STRING: value"
        lines = res.stdout.splitlines()
        parsed = []
        # Build a mapping of name/path/status from hrSWRunName (2), hrSWRunPath (4), hrSWRunStatus (7)
        # We'll group by index: .1.3.6.1.2.1.25.4.2.1.2.i, .1.3.6.1.2.1.25.4.2.1.4.i, .1.3.6.1.2.1.25.4.2.1.7.i
        names = {}
        paths = {}
        statuses = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            # Split OID from value: "oid = type: value" or "oid type value"
            # Standard SNMP output: ".1.3.6.1.2.1.25.4.2.1.2.1 = STRING: "cron"
            idx = line.find("=")
            if idx == -1:
                continue
            oid_part = line[:idx].strip()
            value_part = line[idx+1:].strip()
            # Extract index: last number after last dot
            last_dot = oid_part.rfind(".")
            if last_dot == -1:
                continue
            idx_str = oid_part[last_dot+1:].strip()
            # Extract type and value
            type_val = value_part.split(":", 1)
            if len(type_val) != 2:
                continue
            value = type_val[1].strip().strip('"')
            # Determine type
            oid_head = oid_part[:last_dot].strip()
            if oid_head.endswith(".2"):
                names[idx_str] = value
            elif oid_head.endswith(".4"):
                paths[idx_str] = value
            elif oid_head.endswith(".7"):
                statuses[idx_str] = value
        
        # Align by index
        all_idx = set(names.keys()) | set(paths.keys()) | set(statuses.keys())
        for idx in all_idx:
            name = names.get(idx, "")
            path = paths.get(idx, "")
            status = statuses.get(idx, "")
            if name or path or status:
                parsed.append([name, path, status])
        
        section = _parse_hr_ps(parsed)
        
        discovered = {}
        for proc in section:
            for rule in rules:
                match_name_or_path = rule.get("match_name_or_path")
                match_status = rule.get("match_status")
                
                # Skip default rule if present
                if match_name_or_path == None and match_status == None:
                    continue
                
                matches = _match_process(proc, match_name_or_path, match_status, None)
                if not matches:
                    continue
                
                match_groups = []
                if matches == True:
                    pass
                else:
                    match_groups = [g if g else "" for g in matches.groups()] if hasattr(matches, "groups") else []
                
                descr = rule.get("descr", "%s")
                # Replace %s with process name (simplified)
                service_descr = descr.replace("%s", proc["name"])
                
                # Default params: match rules
                service_params = {
                    "match_name_or_path": match_name_or_path,
                    "match_status": match_status,
                    "match_groups": match_groups,
                }
                if service_params not in discovered.values():
                    # Avoid duplicates
                    pass
                
                discovered[service_descr] = {
                    "match_name_or_path": match_name_or_path,
                    "match_status": match_status,
                    "match_groups": match_groups,
                }
        
        out = []
        for item, p in discovered.items():
            out.append({
                "item": item,
                "params": p,
                "metrics": ["processes"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d process items" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode
    item = params.get("item", "")
    # Get SNMP data
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost"), ".1.3.6.1.2.1.25.4.2.1"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    parsed = []
    names = {}
    paths = {}
    statuses = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        idx = line.find("=")
        if idx == -1:
            continue
        oid_part = line[:idx].strip()
        value_part = line[idx+1:].strip()
        last_dot = oid_part.rfind(".")
        if last_dot == -1:
            continue
        idx_str = oid_part[last_dot+1:].strip()
        type_val = value_part.split(":", 1)
        if len(type_val) != 2:
            continue
        value = type_val[1].strip().strip('"')
        oid_head = oid_part[:last_dot].strip()
        if oid_head.endswith(".2"):
            names[idx_str] = value
        elif oid_head.endswith(".4"):
            paths[idx_str] = value
        elif oid_head.endswith(".7"):
            statuses[idx_str] = value
    
    all_idx = set(names.keys()) | set(paths.keys()) | set(statuses.keys())
    for idx in all_idx:
        name = names.get(idx, "")
        path = paths.get(idx, "")
        status = statuses.get(idx, "")
        if name or path or status:
            parsed.append([name, path, status])
    
    section = _parse_hr_ps(parsed)
    
    # Extract check parameters
    match_name_or_path = params.get("match_name_or_path")
    match_status = params.get("match_status")
    match_groups = params.get("match_groups")
    
    matching = _match_all_processes(section, item, params)
    count_processes = len(matching)
    
    # Levels: (lower_warn, lower_crit, upper_warn, upper_crit)
    levels = params.get("levels", (1, 1, 99999, 99999))
    lc, lw, uw, uc = levels
    
    # Determine state
    state = "OK"
    summary_parts = []
    summary_parts.append("Processes: %d" % count_processes)
    
    # Lower levels
    if lc != None and count_processes < lc:
        state = "CRIT"
    elif lw != None and count_processes < lw:
        state = "WARN"
    
    # Upper levels
    if uc != None and count_processes > uc:
        state = "CRIT"
    elif uw != None and count_processes > uw:
        state = "WARN"
    
    # Process states
    process_state_map = dict(params.get("status", []))
    for proc in matching:
        key = proc["state_key"]
        state_val = process_state_map.get(key, 0)
        long_ = proc["state_long"]
        short_ = proc["state_short"]
        if long_:
            state_info = short_ + " (" + long_ + ")"
        else:
            state_info = short_
    
    # Build summary
    state_counts = {}
    for proc in matching:
        key = proc["state_key"]
        if key not in state_counts:
            state_counts[key] = 0
        state_counts[key] += 1
    
    for key, cnt in state_counts.items():
        if key in _HR_PS_STATUS_MAP:
            short_ = _HR_PS_STATUS_MAP[key][1]
            long_ = _HR_PS_STATUS_MAP[key][2]
            if long_:
                state_info = short_ + " (" + long_ + ")"
            else:
                state_info = short_
            summary_parts.append("%d %s" % (cnt, state_info))
    
    summary = ", ".join(summary_parts)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"processes": count_processes},
            "details": ""
        }
    }