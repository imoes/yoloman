def main(ctx, params):
    # SNMP community and host
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    if params.get("_discover"):
        # Walk status tree for VS names and IDs
        status_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.2620.1.16.22.1.1"
        ], mutates=False)
        
        # Walk counter tree for traffic data
        counter_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.2620.1.16.23.1.1"
        ], mutates=False)
        
        # Parse status table: VSID -> vs_name
        vsid_name_map = {}
        for line in status_res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value = parts[1].strip()
            if value.startswith("\""):
                value = value[1:-1]
            # OID format: .1.3.6.1.4.1.2620.1.16.22.1.1.3.1.0 = "my_vsid"
            # OID ends with .1.x where x=3 is vs_name
            if oid_full.endswith(".3.1.0"):
                oid_parts = oid_full.split(".")
                if len(oid_parts) >= 3:
                    vsid = oid_parts[-3]
                    vsid_name_map[vsid] = value
        
        # Parse counter table and build items
        out = []
        for line in counter_res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value = parts[1].strip()
            if value.startswith("\""):
                value = value[1:-1]
            # OID format: .1.3.6.1.4.1.2620.1.16.23.1.1.2.1.0 = 104470
            # oid 2 = bytes_accepted (index 0)
            if oid_full.endswith(".2.1.0"):
                oid_parts = oid_full.split(".")
                if len(oid_parts) >= 3:
                    vsid = oid_parts[-3]
                    if value.isdigit():
                        bytes_acc = int(value)
                        if bytes_acc >= 0:
                            vs_name = vsid_name_map.get(vsid, "VS" + vsid)
                            out.append({
                                "item": vs_name + " " + vsid,
                                "params": {
                                    "bytes_accepted": ("no_levels", None),
                                    "bytes_dropped": ("no_levels", None),
                                    "bytes_rejected": ("no_levels", None),
                                },
                                "metrics": ["bytes_accepted", "bytes_dropped", "bytes_rejected"],
                            })
        
        return {
            "changed": False,
            "msg": "discovered %d VS instances" % len(out),
            "data": {"discovery": out},
        }
    
    # Check mode
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Fetch counter data for this item
    counter_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.2620.1.16.23.1.1"
    ], mutates=False)
    
    # Parse to find values for this item
    # The item is like "VS1 123" - need to match by parsing
    values = {}
    
    for line in counter_res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value = parts[1].strip()
        if value.startswith("\""):
            value = value[1:-1]
        
        # OID format: .1.3.6.1.4.1.2620.1.16.23.1.1.{oid}.{index}.0
        # oid 2=bytes_accepted, 4=bytes_dropped, 5=bytes_rejected
        if oid_full.endswith(".0"):
            oid_parts = oid_full.split(".")
            if len(oid_parts) >= 10:
                oid_num = oid_parts[-2]
                vsid = oid_parts[-3]
                
                # Only process if vsid matches our item (extract from item)
                item_parts = item.split(" ")
                if len(item_parts) >= 2:
                    item_vsid = item_parts[-1]
                    if vsid != item_vsid:
                        continue
                
                    if value.isdigit():
                        val = int(value)
                        if oid_num == "2":
                            values["bytes_accepted"] = val
                        elif oid_num == "4":
                            values["bytes_dropped"] = val
                        elif oid_num == "5":
                            values["bytes_rejected"] = val
    
    # Check if we have any data
    if not values:
        return {
            "changed": False,
            "msg": "no traffic data found for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Get thresholds from params (Checkmk defaults: no_levels)
    bytes_accepted_levels = params.get("bytes_accepted", ("no_levels", None))
    bytes_dropped_levels = params.get("bytes_dropped", ("no_levels", None))
    bytes_rejected_levels = params.get("bytes_rejected", ("no_levels", None))
    
    # Process each metric - using simple rate calculation with stored values
    # Since we can't persist state in Starlark, we'll report raw values
    # (In real use, Checkmk would handle rate calculation via value_store)
    metrics = {}
    state = "OK"
    msg_parts = []
    
    for key in ["bytes_accepted", "bytes_dropped", "bytes_rejected"]:
        value = values.get(key)
        if value == None:
            continue
        
        metrics[key] = value
        label = "Total number of " + key.replace("_", " ")
        
        # Check levels
        levels_param = bytes_accepted_levels if key == "bytes_accepted" else (
            bytes_dropped_levels if key == "bytes_dropped" else bytes_rejected_levels
        )
        level_type = levels_param[0]
        levels = levels_param[1] if len(levels_param) > 1 else None
        
        if level_type == "fixed" and levels != None:
            warn = levels[0]
            crit = levels[1]
            if value >= crit:
                state = "CRIT"
                msg_parts.append("%s: %d" % (label, value))
            elif value >= warn:
                state = "WARN" if state == "OK" else state
                msg_parts.append("%s: %d" % (label, value))
            else:
                msg_parts.append("%s: %d" % (label, value))
        else:
            msg_parts.append("%s: %d" % (label, value))
    
    msg = ", ".join(msg_parts) if msg_parts else "no traffic data"
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }
