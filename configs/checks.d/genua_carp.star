def _linkstate_name(st):
    names = {"0": "unknown", "1": "down", "2": "up", "3": "hd", "4": "fd"}
    return names.get(st, st)

def _carpstate_name(st):
    names = {"0": "init", "1": "backup", "2": "master"}
    return names.get(st, st)

def _probe_genua(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                   ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        if res.stdout == "" and res.stderr == "":
            return None
        # Check if 127 or timeout means not present
        if res.rc == 127:
            return None
    sys_descr = res.stdout.strip()
    if "genuscreen" in sys_descr or "genubox" in sys_descr or "genucrypt" in sys_descr:
        return sys_descr
    return None

def _fetch_table(ctx, host, community, base_oid, col_oid):
    column_oid = base_oid + "." + col_oid if not col_oid.startswith(".") else base_oid + col_oid
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host,
                   column_oid], mutates=False)
    if res.rc == 127:
        return {}
    if res.rc != 0:
        return {}
    result = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0]
        value = parts[1]
        # oid_full is like "<column_oid>.<index>"
        # strip the column_oid prefix to get index
        if oid_full.startswith(column_oid):
            index = oid_full[len(column_oid) + 1:]
            result[index] = value
    return result

def _get_carp_interfaces(ctx, host, community):
    bases = [".1.3.6.1.4.1.3137.2.1.2.1", ".1.3.6.1.4.1.3717.2.1.2.1"]
    
    # Collect all indices across both bases
    all_data = {}  # index -> {"ifName":..., "ifLinkState":..., "ifCarpState":...}
    found_data = False
    
    for base in bases:
        names = _fetch_table(ctx, host, community, base, "2")
        link_states = _fetch_table(ctx, host, community, base, "4")
        carp_states = _fetch_table(ctx, host, community, base, "7")
        
        for index in names:
            found_data = True
            if index not in all_data:
                all_data[index] = {}
            all_data[index]["ifName"] = names[index]
            if index in link_states:
                all_data[index]["ifLinkState"] = link_states[index]
            if index in carp_states:
                all_data[index]["ifCarpState"] = carp_states[index]
        
        # Also check indices from other tables
        for index in link_states:
            found_data = True
            if index not in all_data:
                all_data[index] = {}
            all_data[index]["ifLinkState"] = link_states[index]
        
        for index in carp_states:
            found_data = True
            if index not in all_data:
                all_data[index] = {}
            all_data[index]["ifCarpState"] = carp_states[index]
    
    if not found_data:
        return []
    
    interfaces = []
    for index, data in all_data.items():
        ifName = data.get("ifName", "")
        ifLinkState = data.get("ifLinkState", "0")
        ifCarpState = data.get("ifCarpState", "0")
        interfaces.append((ifName, ifLinkState, ifCarpState))
    
    return interfaces

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        # First verify GENUA device
        sys_descr = _probe_genua(ctx, host, community)
        if sys_descr == None:
            return {"changed": False, "msg": "no genua device found", 
                    "data": {"discovery": []}}
        
        interfaces = _get_carp_interfaces(ctx, host, community)
        discovery = []
        seen = {}
        for ifName, ifLinkState, ifCarpState in interfaces:
            if ifCarpState in ["0", "1", "2"]:
                if ifName not in seen:
                    seen[ifName] = True
                    discovery.append({
                        "item": ifName,
                        "params": {},
                        "metrics": []
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d carp interfaces" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode
    item = params.get("item", "")
    
    # Verify GENUA device
    sys_descr = _probe_genua(ctx, host, community)
    if sys_descr == None:
        return {
            "changed": False,
            "msg": "no genua device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    interfaces = _get_carp_interfaces(ctx, host, community)
    
    # Collect all nodes (each SNMP base is a "node")
    bases = [".1.3.6.1.4.1.3137.2.1.2.1", ".1.3.6.1.4.1.3717.2.1.2.1"]
    
    nodes = 0
    masters = 0
    output = ""
    state = 0
    
    # We need to walk per-base to count nodes
    # Re-fetch per base to understand node structure
    per_base = []
    for base_idx, base in enumerate(bases):
        names = _fetch_table(ctx, host, community, base, "2")
        link_states = _fetch_table(ctx, host, community, base, "4")
        carp_states = _fetch_table(ctx, host, community, base, "7")
        
        if names or link_states or carp_states:
            nodes += 1
            node_interfaces = []
            for index in names:
                node_interfaces.append((names[index], link_states.get(index, "0"), carp_states.get(index, "0")))
            per_base.append(node_interfaces)
    
    if nodes == 0:
        return {
            "changed": False,
            "msg": "no carp interfaces found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if nodes > 1:
        prefix = "Cluster test: "
    else:
        prefix = "Node test: "
    
    # Check if item exists in any node
    item_found = False
    
    for node_interfaces in per_base:
        for ifName, ifLinkState, ifCarpState in node_interfaces:
            if ifName == item and ifCarpState == "2":
                item_found = True
                masters += 1
                ifLinkStateStr = _linkstate_name(ifLinkState)
                ifCarpStateStr = _carpstate_name(ifCarpState)
                
                if masters == 1:
                    if nodes > 1:
                        output = "one "
                    output += "node in carp state %s with IfLinkState %s" % (ifCarpStateStr, ifLinkStateStr)
                    if ifLinkState == "2":
                        state = 0
                    elif ifLinkState == "1":
                        state = 2
                    elif ifLinkState in ["0", "3"]:
                        state = 1
                    else:
                        state = 3
                else:
                    state = 2
                    output = "%d nodes in carp state %s on cluster with %d nodes" % (masters, ifCarpStateStr, nodes)
            elif ifName == item and nodes == 1:
                item_found = True
                ifLinkStateStr = _linkstate_name(ifLinkState)
                ifCarpStateStr = _carpstate_name(ifCarpState)
                output = "node in carp state %s with IfLinkState %s" % (ifCarpStateStr, ifLinkStateStr)
                if ifCarpState == "1" and ifLinkState == "1":
                    state = 0
                else:
                    state = 1
    
    # No masters found in cluster
    if nodes > 1 and masters == 0:
        state = 2
        output = "No master found on cluster with %d nodes" % nodes
    
    if not item_found:
        return {
            "changed": False,
            "msg": "no such carp interface: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state_name = state_map.get(state, "UNKNOWN")
    
    output = prefix + output
    
    return {
        "changed": False,
        "msg": output,
        "data": {"state": state_name, "metrics": {}, "details": ""
    }
}