def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.3854.2.3.3.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        # Parse snmpwalk output: ".OID = TYPE: value" format
        lines = res.stdout.splitlines()
        # Map OID suffixes to values
        # base: .1.3.6.1.4.1.3854.2.3.3.1
        # oids: 2 (description), 4 (percent), 6 (status), 8 (online)
        # Expected full OIDs: .1.3.6.1.4.1.3854.2.3.3.1.2, .1.3.6.1.4.1.3854.2.3.3.1.4, ...
        description_map = {}
        percent_map = {}
        status_map = {}
        online_map = {}
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
            # Split OID and value
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value = parts[1].strip()
            # Extract numeric OID (remove leading dot)
            if oid.startswith("."):
                oid_num = oid[1:]
            else:
                oid_num = oid
            
            # Match suffixes: 2, 4, 6, 8
            suffix = oid_num.rsplit(".", 1)[-1] if "." in oid_num else oid_num
            if suffix == "2":
                # Description: value is in quotes or plain
                # Remove quotes if present
                if value.startswith('"') and value.endswith('"'):
                    val = value[1:-1]
                elif value.startswith('STRING:'):
                    val = value[7:].strip().strip('"')
                else:
                    val = value
                description_map[oid_num.rsplit(".", 1)[0]] = val
            elif suffix == "4":
                # Percent
                if value.startswith('INTEGER:'):
                    val = int(value[8:])
                elif value.startswith('Gauge32:'):
                    val = int(value[8:])
                else:
                    val = int(value) if value.isdigit() else 0
                percent_map[oid_num.rsplit(".", 1)[0]] = val
            elif suffix == "6":
                # Status
                if value.startswith('INTEGER:'):
                    val = int(value[8:])
                else:
                    val = int(value) if value.isdigit() else 1
                status_map[oid_num.rsplit(".", 1)[0]] = str(val)
            elif suffix == "8":
                # Online
                if value.startswith('INTEGER:'):
                    val = int(value[8:])
                else:
                    val = int(value) if value.isdigit() else 2
                online_map[oid_num.rsplit(".", 1)[0]] = str(val)
        
        # Build sections: for each description key
        discovered = []
        for desc_oid in description_map:
            online = online_map.get(desc_oid, "2")
            if online == "1":
                item = description_map[desc_oid]
                # Suggested default params: levels and levels_lower
                params_sugg = {"warn": 60.0, "crit": 65.0, "warn_lower": 30.0, "crit_lower": 35.0}
                discovered.append({
                    "item": item,
                    "params": params_sugg,
                    "metrics": ["humidity"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # CHECK MODE
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.3854.2.3.3.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse response
    section = []
    lines = res.stdout.splitlines()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()
        if oid.startswith("."):
            oid_num = oid[1:]
        else:
            oid_num = oid
        
        # Find base OID and suffix
        base_oid = ".1.3.6.1.4.1.3854.2.3.3.1"
        if oid_num.startswith(base_oid[1:]):
            suffix = oid_num[len(base_oid):].lstrip(".")
            if suffix in ["2", "4", "6", "8"]:
                # Get common prefix for this entry
                entry_oid = oid_num.rsplit(".", 1)[0] if "." in oid_num else oid_num
                # We need to group by entry_oid
                pass
    
    # Alternative: parse by building rows manually
    # We'll collect all entries with their fields
    entries = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()
        if oid.startswith("."):
            oid_num = oid[1:]
        else:
            oid_num = oid
        
        # Check if this is an akcp_exp_humidity OID
        if not oid_num.startswith(".1.3.6.1.4.1.3854.2.3.3.1"):
            continue
        
        # Get base index
        suffix = oid_num.rsplit(".", 1)[-1]
        if suffix in ["2", "4", "6", "8"]:
            # Extract index: .1.3.6.1.4.1.3854.2.3.3.1.2.1 -> 1
            parts_oid = oid_num.split(".")
            if len(parts_oid) >= 9:
                index = parts_oid[-1]
            else:
                continue
            if index not in entries:
                entries[index] = ["", 0, "1", "2"]  # description, percent, status, online
            # Map suffix to field: 2->0, 4->1, 6->2, 8->3
            field_map = {"2": 0, "4": 1, "6": 2, "8": 3}
            field = field_map[suffix]
            if suffix == "2":
                if value.startswith('"') and value.endswith('"'):
                    val = value[1:-1]
                elif value.startswith('STRING:'):
                    val = value[7:].strip().strip('"')
                else:
                    val = value
                entries[index][0] = val
            elif suffix == "4":
                if value.startswith('INTEGER:'):
                    val = int(value[8:])
                elif value.startswith('Gauge32:'):
                    val = int(value[8:])
                else:
                    val = int(value) if value.isdigit() else 0
                entries[index][1] = val
            elif suffix == "6":
                if value.startswith('INTEGER:'):
                    val = int(value[8:])
                else:
                    val = int(value) if value.isdigit() else 1
                entries[index][2] = str(val)
            elif suffix == "8":
                if value.startswith('INTEGER:'):
                    val = int(value[8:])
                else:
                    val = int(value) if value.isdigit() else 2
                entries[index][3] = str(val)
    
    section = []
    for idx in entries:
        section.append(entries[idx])
    
    # Find matching item
    found = False
    for desc, percent, status, online in section:
        if desc == item:
            found = True
            # Online check
            if online != "1":
                return {
                    "changed": False,
                    "msg": "sensor is offline",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}
                }
            
            # Status check
            akcp_sensor_level_states = {
                "1": ("CRIT", "no status"),
                "2": ("OK", "normal"),
                "3": ("WARN", "high warning"),
                "4": ("CRIT", "high critical"),
                "5": ("WARN", "low warning"),
                "6": ("CRIT", "low critical"),
                "7": ("CRIT", "sensor error"),
            }
            if status in ["1", "7"]:
                state_name = akcp_sensor_level_states[status][1]
                state = akcp_sensor_level_states[status][0]
                return {
                    "changed": False,
                    "msg": "State: " + state_name,
                    "data": {"state": state, "metrics": {}, "details": ""}
                }
            
            # Humidity check
            if percent:
                # Extract levels from params
                # Checkmk uses 'levels' (upper) and 'levels_lower' (lower)
                # Default: levels=(60.0,65.0), levels_lower=(30.0,35.0)
                warn_upper = params.get("warn", params.get("levels", (60.0, 65.0))[0] if isinstance(params.get("levels", (60.0, 65.0)), tuple) else 60.0)
                crit_upper = params.get("crit", params.get("levels", (60.0, 65.0))[1] if isinstance(params.get("levels", (60.0, 65.0)), tuple) else 65.0)
                warn_lower = params.get("warn_lower", params.get("levels_lower", (30.0, 35.0))[0] if isinstance(params.get("levels_lower", (30.0, 35.0)), tuple) else 30.0)
                crit_lower = params.get("crit_lower", params.get("levels_lower", (30.0, 35.0))[1] if isinstance(params.get("levels_lower", (30.0, 35.0)), tuple) else 35.0)
                
                # Handle tuple params
                levels = params.get("levels")
                if levels != None and isinstance(levels, list):
                    warn_upper = levels[0]
                    crit_upper = levels[1]
                levels_lower = params.get("levels_lower")
                if levels_lower != None and isinstance(levels_lower, list):
                    warn_lower = levels_lower[0]
                    crit_lower = levels_lower[1]
                
                humidity_val = int(percent)
                state = "OK"
                summary_parts = []
                
                # Check upper levels first
                if humidity_val >= crit_upper:
                    state = "CRIT"
                    summary_parts.append("CRIT (at %d%%, threshold %d%%)" % (humidity_val, crit_upper))
                elif humidity_val >= warn_upper:
                    state = "WARN"
                    summary_parts.append("WARN (at %d%%, threshold %d%%)" % (humidity_val, warn_upper))
                elif humidity_val <= crit_lower:
                    state = "CRIT"
                    summary_parts.append("CRIT (at %d%%, lower threshold %d%%)" % (humidity_val, crit_lower))
                elif humidity_val <= warn_lower:
                    state = "WARN"
                    summary_parts.append("WARN (at %d%%, lower threshold %d%%)" % (humidity_val, warn_lower))
                
                summary_parts.insert(0, "Humidity %d%%" % humidity_val)
                msg = ", ".join(summary_parts)
                return {
                    "changed": False,
                    "msg": msg,
                    "data": {"state": state, "metrics": {"humidity": humidity_val}, "details": ""}
                }
            
            return {
                "changed": False,
                "msg": "no humidity data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
    
    if not found:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
