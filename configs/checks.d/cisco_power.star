def main(ctx, params):
    # Constants
    cisco_power_states = (
        "",
        "normal",
        "warning",
        "critical",
        "shutdown",
        "not present",
        "not functioning",
    )

    cisco_power_sources = (
        "",
        "unknown",
        "AC",
        "DC",
        "external power supply",
        "internal redundant",
    )

    def item_name_from(description):
        splitted = [x.strip() for x in description.split(",")]
        if len(splitted) == 1:
            device_description = description
        elif ("#" in splitted[-1]) or ("Power" in splitted[-1]):
            device_description = " ".join(splitted)
        elif splitted[-1].startswith("PS"):
            device_description = " ".join([splitted[0], splitted[-1].split(" ")[0]])
        elif splitted[-2].startswith("PS"):
            device_description = " ".join(splitted[:-2] + splitted[-2].split(" ")[:-1])
        elif splitted[-2].startswith("Status"):
            device_description = " ".join(splitted[:-2])
        else:
            device_description = " ".join(splitted[:-1])
        result = device_description.replace("#", " ")
        if result == "":
            result = "supply"
        return result

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.9.9.13.1.5.1"

    if params.get("_discover") == True:
        # Discover power supplies
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        
        # Parse snmpwalk output into structured data
        entries = {}
        for line in res.stdout.splitlines():
            if line == "":
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            
            oid_full = parts[0]
            # The value starts after " = "
            eq_pos = line.find(" = ")
            if eq_pos == -1:
                continue
            value_str = line[eq_pos + 3:].strip()
            
            # Get the index from the end of the OID
            if oid_full.endswith(".1"):
                sid = value_str
                entries[sid] = [sid, "", "", ""]
            elif oid_full.endswith(".2"):
                sid = oid_full.rsplit(".", 1)[-1]
                entries[sid][1] = value_str.strip('"')
            elif oid_full.endswith(".3"):
                sid = oid_full.rsplit(".", 1)[-1]
                entries[sid][2] = value_str
            elif oid_full.endswith(".4"):
                sid = oid_full.rsplit(".", 1)[-1]
                entries[sid][3] = value_str
        
        # Filter out entries with state "5" (not present)
        filtered = []
        for key in entries:
            entry = entries[key]
            if entry[2] != "5":
                filtered.append(entry)
        
        # Discover items with uniqueness handling
        discovered = {}
        for entry in filtered:
            sid = entry[0]
            textinfo = entry[1]
            item_name = item_name_from(textinfo)
            if item_name not in discovered:
                discovered[item_name] = []
            discovered[item_name].append(sid)
        
        out = []
        for name in discovered:
            entries_list = discovered[name]
            if len(entries_list) == 1:
                out.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })
            else:
                for entry in entries_list:
                    out.append({
                        "item": name + " " + str(entry),
                        "params": {},
                        "metrics": []
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode - specific item
    item = params.get("item", "")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)
    
    # Parse snmpwalk output into structured data
    entries = {}
    for line in res.stdout.splitlines():
        if line == "":
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        
        oid_full = parts[0]
        # The value starts after " = "
        eq_pos = line.find(" = ")
        if eq_pos == -1:
            continue
        value_str = line[eq_pos + 3:].strip()
        
        if oid_full.endswith(".1"):
            sid = value_str
            entries[sid] = [sid, "", "", ""]
        elif oid_full.endswith(".2"):
            sid = oid_full.rsplit(".", 1)[-1]
            entries[sid][1] = value_str.strip('"')
        elif oid_full.endswith(".3"):
            sid = oid_full.rsplit(".", 1)[-1]
            entries[sid][2] = value_str
        elif oid_full.endswith(".4"):
            sid = oid_full.rsplit(".", 1)[-1]
            entries[sid][3] = value_str
    
    # Find matching item
    for entry in entries.values():
        sid = entry[0]
        textinfo = entry[1]
        state_str = entry[2]
        source_str = entry[3]
        item_name_base = item_name_from(textinfo)
        if item == item_name_base or item == item_name_base + " " + str(sid) or item == item_name_base + "/" + str(sid):
            state = int(state_str)
            source = int(source_str)
            
            # Map state to Checkmk state
            if state == 1:
                state_out = "OK"
            elif state == 2:
                state_out = "WARN"
            else:
                state_out = "CRIT"
            
            if state < len(cisco_power_states):
                state_name = cisco_power_states[state]
            else:
                state_name = "unknown"
            if source < len(cisco_power_sources):
                source_name = cisco_power_sources[source]
            else:
                source_name = "unknown"
            
            return {
                "changed": False,
                "msg": "Status: %s, Source: %s" % (state_name, source_name),
                "data": {
                    "state": state_out,
                    "metrics": {},
                    "details": ""
                }
            }
    
    # Item not found
    return {
        "changed": False,
        "msg": "Power supply not found: %s" % item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }
