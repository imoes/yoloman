# Constants for state mappings
_ADMIN_STATES = {
    "1": {"state": "WARN", "name": "not_supported"},
    "2": {"state": "OK", "name": "locked"},
    "3": {"state": "CRIT", "name": "shutting_down"},
    "4": {"state": "CRIT", "name": "unlocked"},
}

_OPER_STATES = {
    "1": {"state": "WARN", "name": "not_supported"},
    "2": {"state": "CRIT", "name": "disabled"},
    "3": {"state": "OK", "name": "enabled"},
    "4": {"state": "CRIT", "name": "dangerous"},
}

def _parse_snmp_table(res):
    """Parse raw snmpwalk output into list of rows.
    Each line: '<OID> = <TYPE>: <value>' -> extract last segment and value."""
    lines = res.stdout.splitlines()
    rows = []
    for line in lines:
        if not line:
            continue
        # Split on " = " to separate OID from value
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        value_part = parts[1]
        # Determine value type and extract value
        if value_part.startswith("INTEGER: "):
            val = value_part[9:]
        elif value_part.startswith("STRING: "):
            # Remove surrounding quotes if present
            sval = value_part[8:]
            if len(sval) >= 2 and sval[0] == '"' and sval[-1] == '"':
                sval = sval[1:-1]
            val = sval
        elif value_part.startswith("Counter32: "):
            val = value_part[11:]
        elif value_part.startswith("Gauge32: "):
            val = value_part[9:]
        elif value_part.startswith("OID: "):
            val = value_part[5:]
        else:
            # Fallback: try to take the whole part as-is
            val = value_part.strip()
        rows.append(val)
    return rows

def _chunk_list(lst, size):
    """Split list into chunks of given size."""
    out = []
    for i in range(0, len(lst), size):
        out.append(lst[i:i + size])
    return out

def main(ctx, params):
    if params.get("_discover"):
        # Walk both tables
        # Table 1: base=".1.3.6.1.4.1.25506.2.6.1.1.1.1", oids=[OIDEnd(), "2", "3", "6", "8", "12", "10"]
        # Table 2: base=".1.3.6.1.2.1.47.1.1.1.1", oids=[OIDEnd(), OIDCached("2")] - but we cannot cache;
        # Instead, use the entity info OID directly: .1.3.6.1.2.1.47.1.1.1.1.1.7 (entPhysicalName)
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Walk main table (hp_hh3c_ext)
        res1 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.4.1.25506.2.6.1.1.1.1"
        ], mutates=False)
        if res1.rc != 0:
            fail("snmpwalk failed for hp_hh3c_ext: " + res1.stderr)
        
        # Walk entity physical names table
        res2 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.2.1.47.1.1.1.1.1.7"
        ], mutates=False)
        if res2.rc != 0:
            fail("snmpwalk failed for entity names: " + res2.stderr)
        
        # Parse entity names into dict: index -> name
        entity_info = {}
        for line in res2.stdout.splitlines():
            if not line:
                continue
            # Format: .1.3.6.1.2.1.47.1.1.1.1.1.7.<index> = STRING: "<name>"
            oid_part = line.split(" = ")[0]
            val_part = line.split(" = ")[1]
            if len(oid_part.split(".")) < 14:
                continue
            idx = oid_part.rsplit(".", 1)[-1]
            # Strip quotes if STRING
            name = val_part.strip()
            if name.startswith('"') and name.endswith('"'):
                name = name[1:-1]
            entity_info[idx] = name
        
        # Parse main table lines
        lines1 = res1.stdout.splitlines()
        entries = []
        for line in lines1:
            if not line:
                continue
            # Format: .1.3.6.1.4.1.25506.2.6.1.1.1.1.<index>.<oid> = <type>: <value>
            # We'll gather per-index data: index, admin_state, oper_state, cpu, mem_usage, temperature, mem_size
            # Collect all OIDs for each index by scanning lines
            pass  # We'll handle this differently below
        
        # Simpler: parse all OID suffixes and values into dict by index
        # Keys: (index, oid_suffix)
        # Then reconstruct rows
        raw_table1 = {}
        for line in lines1:
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value_raw = parts[1].strip()
            # Extract index from OID: base + index + oid_suffix
            # .1.3.6.1.4.1.25506.2.6.1.1.1.1.<index>.<oid_suffix>
            # So split by '.' and take index = -2
            tokens = oid.split(".")
            if len(tokens) < 14:
                continue
            index = tokens[-2]
            oid_suffix = tokens[-1]
            # Extract numeric value
            if value_raw.startswith("INTEGER: "):
                val = value_raw[9:]
            elif value_raw.startswith("STRING: "):
                sval = value_raw[8:]
                if sval.startswith('"') and sval.endswith('"'):
                    sval = sval[1:-1]
                val = sval
            elif value_raw.startswith("Gauge32: "):
                val = value_raw[9:]
            elif value_raw.startswith("Counter32: "):
                val = value_raw[11:]
            else:
                val = value_raw
            raw_table1[(index, oid_suffix)] = val
        
        # Group by index to form rows
        by_index = {}
        for (index, suffix), val in raw_table1.items():
            by_index.setdefault(index, {})
            by_index[index][suffix] = val
        
        # Build entries list
        out = []
        for index, cols in by_index.items():
            # Required columns: 2=adminState, 3=operState, 6=cpuUsage, 8=memUsage, 12=temperature, 10=memSize
            admin_state = cols.get("2", "")
            oper_state = cols.get("3", "")
            cpu = cols.get("6", "")
            mem_usage = cols.get("8", "")
            temperature = cols.get("12", "")
            mem_size = cols.get("10", "")
            
            # Skip invalid entries
            if not mem_size.isdigit() or int(mem_size) <= 0:
                continue
            if temperature == "":
                continue
            
            name = entity_info.get(index, "")
            item = (name + " " + index).strip()
            # Only yield if temperature is valid (not 65535)
            if temperature.isdigit() and int(temperature) != 65535:
                out.append({
                    "item": item,
                    "params": {},
                    "metrics": ["admin_state", "oper_state"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d devices" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode (non-discovery)
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item required", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch main table
    res1 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.25506.2.6.1.1.1.1"
    ], mutates=False)
    if res1.rc != 0:
        fail("snmpwalk failed: " + res1.stderr)
    
    # Fetch entity names
    res2 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.2.1.47.1.1.1.1.1.7"
    ], mutates=False)
    if res2.rc != 0:
        fail("snmpwalk failed for entity names: " + res2.stderr)
    
    # Parse entity names
    entity_info = {}
    for line in res2.stdout.splitlines():
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        val_part = parts[1].strip()
        tokens = oid.split(".")
        if len(tokens) < 14:
            continue
        idx = tokens[-2]
        name = val_part.strip()
        if name.startswith('"') and name.endswith('"'):
            name = name[1:-1]
        entity_info[idx] = name
    
    # Parse main table into dict by index
    raw_table1 = {}
    for line in res1.stdout.splitlines():
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value_raw = parts[1].strip()
        tokens = oid.split(".")
        if len(tokens) < 14:
            continue
        index = tokens[-2]
        oid_suffix = tokens[-1]
        if value_raw.startswith("INTEGER: "):
            val = value_raw[9:]
        elif value_raw.startswith("STRING: "):
            sval = value_raw[8:]
            if sval.startswith('"') and sval.endswith('"'):
                sval = sval[1:-1]
            val = sval
        elif value_raw.startswith("Gauge32: "):
            val = value_raw[9:]
        elif value_raw.startswith("Counter32: "):
            val = value_raw[11:]
        else:
            val = value_raw
        raw_table1[(index, oid_suffix)] = val
    
    by_index = {}
    for (index, suffix), val in raw_table1.items():
        by_index.setdefault(index, {})
        by_index[index][suffix] = val
    
    # Look for item
    found_data = None
    for index, cols in by_index.items():
        name = entity_info.get(index, "")
        candidate = (name + " " + index).strip()
        if candidate == item:
            admin_state = cols.get("2", "")
            oper_state = cols.get("3", "")
            mem_size_str = cols.get("10", "")
            mem_size = int(mem_size_str) if mem_size_str.isdigit() else 0
            if mem_size <= 0:
                continue
            found_data = {
                "admin": admin_state,
                "oper": oper_state
            }
            break
    
    if found_data == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Evaluate states
    admin_state_raw = found_data["admin"]
    oper_state_raw = found_data["oper"]
    
    # Determine states
    admin_info = _ADMIN_STATES.get(admin_state_raw, {"state": "UNKNOWN", "name": "unknown[" + str(admin_state_raw) + "]"})
    oper_info = _OPER_STATES.get(oper_state_raw, {"state": "UNKNOWN", "name": "unknown[" + str(oper_state_raw) + "]"})
    
    # Apply overrides (though check_default_parameters is empty, users might configure)
    # Checkmk uses params like {"admin": {"locked": "OK"}}
    # But our check_default_parameters is {} and check_ruleset_name is "hp_hh3c_ext_states"
    # So we assume params may have overrides: {"admin": {"locked": "OK"}, "oper": {"enabled": "CRIT"}}
    admin_params = params.get("admin", {})
    oper_params = params.get("oper", {})
    
    if admin_info["name"] in admin_params:
        admin_info["state"] = admin_params[admin_info["name"]]
    if oper_info["name"] in oper_params:
        oper_info["state"] = oper_params[oper_info["name"]]
    
    # Compute overall state (CRIT > WARN > OK)
    state_overall = "OK"
    for st in [admin_info["state"], oper_info["state"]]:
        if st == "CRIT":
            state_overall = "CRIT"
        elif st == "WARN" and state_overall != "CRIT":
            state_overall = "WARN"
    
    # Build message
    admin_summary = "Administrative: " + admin_info["name"]
    oper_summary = "Operational: " + oper_info["name"]
    msg = admin_summary + ", " + oper_summary
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_overall,
            "metrics": {},
            "details": admin_summary + " | " + oper_summary
        }
    }