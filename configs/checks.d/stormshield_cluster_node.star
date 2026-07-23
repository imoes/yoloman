# Module: stormshield_cluster_node (read-only Starlark check)
# Translated from Checkmk plugin: cmk.plugins.stormshield.stormshield_cluster_node

# Default thresholds for quality levels (fixed warn=80.0, crit=50.0)
DEFAULT_WARN_QUALITY = 80.0
DEFAULT_CRIT_QUALITY = 50.0

def _parse_snmp_table(lines):
    # Parse snmpwalk output lines into structured data
    data = []
    current_index = None
    row = []
    
    for line in lines:
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract numeric suffix from OID
        if not oid_part.startswith(".1.3.6.1.4.1.11256.1.11.7.1."):
            continue
        
        suffix = oid_part[32:]  # Get after base OID
        if suffix.find(".") == -1:
            continue
        
        idx_part = suffix.split(".")
        if len(idx_part) < 2:
            continue
        
        index_num = idx_part[0]
        col_num = idx_part[1]
        
        # Skip invalid entries
        if not index_num.isdigit() or not col_num.isdigit():
            continue
        
        index_val = int(index_num)
        col_val = int(col_num)
        
        # Process value (strip quotes and get raw value)
        value = ""
        if value_part.startswith("STRING: "):
            value = value_part[8:].strip().strip('"')
        elif value_part.startswith("INTEGER: "):
            value = value_part[9:].strip()
        elif value_part.startswith(" gauge32: ") or value_part.startswith("Gauge32: "):
            value = value_part[10:].strip()
        else:
            value = value_part
        
        # Check if we're starting a new index
        if current_index == None or current_index != index_val:
            # Save previous row if exists
            if len(row) >= 11:
                data.append(row)
            current_index = index_val
            row = [None] * 11
        
        # Place value at correct column (OIDs: 1,2,3,4,5,6,7,8,9,10,11)
        if col_val >= 1 and col_val <= 11:
            row[col_val - 1] = value
    
    # Save last row if exists
    if len(row) >= 11:
        data.append(row)
    
    return data

def _format_percent(value):
    # Format a number as a percent string like Checkmk's render.percent
    return "%f%%" % value

def main(ctx, params):
    # Determine if we're in discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.11256.1.11.7.1"
        ], mutates=False)
        
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        data = _parse_snmp_table(lines)
        
        discovery_items = []
        for row in data:
            if len(row) >= 1:
                item = row[0]  # index field is first in row
                if item != None and item != "":
                    discovery_items.append({
                        "item": str(item),
                        "params": {"quality": ("fixed", (DEFAULT_WARN_QUALITY, DEFAULT_CRIT_QUALITY))},
                        "metrics": ["quality"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d HA nodes" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode: handle single item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.11256.1.11.7.1"
    ], mutates=False)
    
    if res.rc != 0 or res.stdout == "":
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    lines = res.stdout.splitlines()
    data = _parse_snmp_table(lines)
    
    # Find the target node
    target_node = None
    for row in data:
        if len(row) >= 1 and row[0] != None and str(row[0]) == item:
            target_node = row
            break
    
    if target_node == None:
        return {
            "changed": False,
            "msg": "HA node %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Extract values from the row
    # (index, serial, online, model, version, license, quality, priority, forced, active, uptime)
    online = target_node[2] if len(target_node) > 2 else None
    model = target_node[3] if len(target_node) > 3 else ""
    version = target_node[4] if len(target_node) > 4 else ""
    license_ = target_node[5] if len(target_node) > 5 else ""
    quality_str = target_node[6] if len(target_node) > 6 else ""
    priority = target_node[7] if len(target_node) > 7 else ""
    forced = target_node[8] if len(target_node) > 8 else None
    active = target_node[9] if len(target_node) > 9 else None
    
    # Convert quality to float (guard instead of try/except)
    quality = 0.0
    if quality_str != None and quality_str != "":
        # Simple float conversion guard: check for valid number format
        temp_str = quality_str.strip()
        is_valid = temp_str.replace(".", "", 1).lstrip("-").isdigit() if temp_str else False
        if is_valid:
            quality = float(temp_str)
    
    # Determine HA state
    ha_state = ""
    if active == "2":
        ha_state = "active"
    elif active == "1":
        ha_state = "passive"
    else:
        ha_state = "unknown"
    
    # Determine forced flag
    forced_flag = (forced == "1")
    
    # Determine state based on online status
    state = "CRIT" if online != "1" else "OK"
    msg_parts = ["Online"] if online == "1" else ["Offline"]
    
    # Add HA state status
    if forced_flag:
        msg_parts.append("HA-State: %s (forced)" % ha_state)
    else:
        msg_parts.append("HA-State: %s (not forced)" % ha_state)
    
    # Check quality levels
    warn_level = DEFAULT_WARN_QUALITY
    crit_level = DEFAULT_CRIT_QUALITY
    quality_levels = params.get("quality")
    if quality_levels != None:
        if type(quality_levels) == "list" and len(quality_levels) >= 2:
            if quality_levels[0] == "fixed":
                warn_level = float(quality_levels[1])
                crit_level = float(quality_levels[0])
    
    # Check quality levels (lower bound check per Checkmk's "levels_lower")
    # For quality, lower is worse: warn if <= warn, crit if <= crit
    quality_state = "OK"
    if quality <= crit_level:
        quality_state = "CRIT"
    elif quality <= warn_level:
        quality_state = "WARN"
    
    if quality_state != "OK":
        msg_parts.append("Quality: " + _format_percent(quality) + " (warn/crit at " + str(warn_level) + "/" + str(crit_level) + "%)")
    
    # Add static info lines
    msg_parts.append("Model: " + str(model))
    msg_parts.append("Version: " + str(version))
    msg_parts.append("Role: " + str(license_))
    msg_parts.append("Priority: " + str(priority))
    
    # Determine overall state
    if state == "CRIT" or quality_state == "CRIT":
        overall_state = "CRIT"
    elif quality_state == "WARN":
        overall_state = "WARN"
    else:
        overall_state = "OK"
    
    # Prepare return data
    metrics = {"quality": quality}
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": overall_state,
            "metrics": metrics,
            "details": ""
        }
    }