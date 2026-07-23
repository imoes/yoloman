def main(ctx, params):
    # Default parameters from Checkmk source
    levels_lower_warn = 2
    levels_lower_crit = 1

    # Get thresholds from params if provided
    levels_lower = params.get("levels_lower", ("fixed", (levels_lower_warn, levels_lower_crit)))
    if type(levels_lower) == "list" or type(levels_lower) == "tuple":
        # ("fixed", (warn, crit)) format
        if len(levels_lower) >= 2 and (type(levels_lower[1]) == "list" or type(levels_lower[1]) == "tuple") and len(levels_lower[1]) >= 2:
            levels_lower_warn = int(levels_lower[1][0])
            levels_lower_crit = int(levels_lower[1][1])
    elif type(levels_lower) == "dict":
        # Handle dict format if any (not expected from source defaults)
        levels_lower_warn = levels_lower.get("warn", levels_lower_warn)
        levels_lower_crit = levels_lower.get("crit", levels_lower_crit)
    else:
        # Fallback to fixed values
        if len(levels_lower) >= 2 and (type(levels_lower[1]) == "list" or type(levels_lower[1]) == "tuple") and len(levels_lower[1]) >= 2:
            levels_lower_warn = int(levels_lower[1][0])
            levels_lower_crit = int(levels_lower[1][1])

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Discovery mode: fetch pool names from first SNMP tree
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.3375.2.2.5.1.2.1.1"
        ], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            if line.find("=") == -1:
                continue
            value = line.split("=", 1)[1].strip()
            # Extract pool name from SNMP value (string value without quotes)
            if value.startswith("\"") and value.endswith("\""):
                item = value[1:-1]
            else:
                item = value.strip()
            if item != "":
                items.append({"item": item, "params": {"levels_lower": ("fixed", (levels_lower_warn, levels_lower_crit))},
                              "metrics": ["members_up", "members_total"]})
        
        return {
            "changed": False,
            "msg": "discovered %d pools" % len(items),
            "data": {"discovery": items},
        }

    # Check mode: fetch both tables and compute pool status
    item = params.get("item", "")
    
    # Fetch pool summary data: active_members and defined_members
    res_pool = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.3375.2.2.5.1.2.1"
    ], mutates=False)
    
    # Fetch member status data
    res_member = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.3375.2.2.5.3.2.1"
    ], mutates=False)

    # Parse pool summary (name -> active_members, defined_members)
    pool_data = {}
    current_pool = ""
    for line in res_pool.stdout.splitlines():
        if line.find("=") == -1:
            continue
        oid_part, value_part = line.split("=", 1)
        value = value_part.strip()
        # Extract OID ending
        oid_parts = oid_part.strip().rsplit(".", 1)
        if len(oid_parts) < 2:
            continue
        oid_end = oid_parts[-1]
        if oid_end == "1":
            # Pool name
            if value.startswith("\"") and value.endswith("\""):
                current_pool = value[1:-1]
            else:
                current_pool = value.strip()
            if current_pool not in pool_data:
                pool_data[current_pool] = {"active": 0, "defined": 0, "members": []}
        elif oid_end == "8":
            # Active member count
            if value.isdigit():
                count = int(value)
                if current_pool != "":
                    pool_data[current_pool]["active"] = count
        elif oid_end == "23":
            # Total member count
            if value.isdigit():
                count = int(value)
                if current_pool != "":
                    pool_data[current_pool]["defined"] = count

    # Parse member data: pool_name -> members info
    current_member_pool = ""
    port = ""
    monitor_state = 0
    monitor_status = 0
    session_status = 0
    node_name = ""
    for line in res_member.stdout.splitlines():
        if line.find("=") == -1:
            continue
        oid_part, value_part = line.split("=", 1)
        oid_parts = oid_part.strip().rsplit(".", 1)
        if len(oid_parts) < 2:
            continue
        oid_end = oid_parts[-1]
        value = value_part.strip()
        if oid_end == "1":
            # Pool name
            if value.startswith("\"") and value.endswith("\""):
                current_member_pool = value[1:-1]
            else:
                current_member_pool = value.strip()
        elif oid_end == "4":
            # Port
            port = value.strip()
        elif oid_end == "10":
            # Monitor state
            if value.isdigit():
                monitor_state = int(value)
        elif oid_end == "11":
            # Monitor status
            if value.isdigit():
                monitor_status = int(value)
        elif oid_end == "13":
            # Session status
            if value.isdigit():
                session_status = int(value)
        elif oid_end == "19":
            # Node name
            node_name = value.strip()
            # Add member to current pool
            if current_member_pool != "" and current_member_pool in pool_data:
                pool_data[current_member_pool]["members"].append({
                    "port": port,
                    "monitor_state": monitor_state,
                    "monitor_status": monitor_status,
                    "session_status": session_status,
                    "node_name": node_name,
                })
    
    # Find the requested pool item
    pool = pool_data.get(item, None)
    if pool == None:
        return {
            "changed": False,
            "msg": "pool not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    active_members = pool.get("active", 0)
    defined_members = pool.get("defined", 0)
    members_info = pool.get("members", [])

    # Determine state based on active vs defined members with lower levels
    state = "OK"
    if defined_members > 0:
        if active_members <= levels_lower_crit:
            state = "CRIT"
        elif active_members <= levels_lower_warn:
            state = "WARN"
    
    # Build summary message
    msg_parts = ["Members up: %d" % active_members]
    msg_parts.append("Members total: %d" % defined_members)
    
    # Check for down/disabled nodes
    up_states = (4, 28)
    disabled_states = (2, 3, 4, 5)
    down_list = []
    for member in members_info:
        if (
            member["monitor_state"] not in up_states
            or member["monitor_status"] not in up_states
            or member["session_status"] in disabled_states
        ):
            # Extract hostname from node_name (format: "/partition/name")
            node_name = member["node_name"]
            if node_name.startswith("/") and node_name.find("/", 1) != -1:
                parts = node_name.split("/", 3)
                if len(parts) >= 3:
                    host = parts[2]
                else:
                    host = node_name
            else:
                host = node_name
            down_list.append(host + ":" + str(member["port"]))
    
    if len(down_list) > 0:
        msg_parts.append("down/disabled nodes: " + ", ".join(down_list))
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"members_up": active_members, "members_total": defined_members},
            "details": "",
        },
    }
