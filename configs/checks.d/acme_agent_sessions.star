def main(ctx, params):
    # State mapping from Checkmk source: "0" -> OK, "1" -> CRIT, "2-3" -> OK, "4-6" -> WARN
    map_states = {
        "0": ("OK", "disabled"),
        "1": ("CRIT", "out of service"),
        "2": ("OK", "standby"),
        "3": ("OK", "in service"),
        "4": ("WARN", "contraints violation"),
        "5": ("WARN", "in service timed out"),
        "6": ("WARN", "oos provisioned response"),
    }
    
    # Discovery mode: enumerate all hostnames found via SNMP
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.9148.3.2.1.2.2.1"
        # Fetch hostname OID .1.3.6.1.4.1.9148.3.2.1.2.2.1.2
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), base_oid + ".2"
        ], mutates=False)
        out = []
        for line in res.stdout.splitlines():
            # Line format: .1.3.6.1.4.1.9148.3.2.1.2.2.1.2.X = STRING: "hostname"
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            value = parts[1].strip()
            # Extract hostname from STRING: "value"
            hostname = ""
            if value.startswith('"') and value.endswith('"'):
                hostname = value[1:-1]
            elif value.startswith('STRING: "'):
                hostname = value[8:-1]
            else:
                hostname = value
            if hostname != "":
                out.append({
                    "item": hostname,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d agent sessions" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode: verify one item (hostname)
    item = params.get("item", "")
    base_oid = ".1.3.6.1.4.1.9148.3.2.1.2.2.1"
    # Fetch hostname values to build index map
    res_hostnames = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_oid + ".2"
    ], mutates=False)
    
    # Build hostname index map
    hostname_map = {}
    for line in res_hostnames.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value = parts[1].strip()
        # Extract hostname
        hostname = ""
        if value.startswith('"') and value.endswith('"'):
            hostname = value[1:-1]
        elif value.startswith('STRING: "'):
            hostname = value[8:-1]
        else:
            hostname = value
        if hostname != "":
            # Extract index from OID: ...1.2.2.1.2.<index>
            oid_parts = oid_part.split(".")
            if len(oid_parts) > 0:
                index = oid_parts[-1]
                hostname_map[index] = hostname
    
    # Fetch state values
    res_states = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_oid + ".22"
    ], mutates=False)
    
    # Find state for target item
    state_value = ""
    for line in res_states.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value = parts[1].strip()
        # Extract index from OID
        oid_parts = oid_part.split(".")
        if len(oid_parts) == 0:
            continue
        index = oid_parts[-1]
        # Get hostname for this index
        hostname = hostname_map.get(index, "")
        if hostname != item:
            continue
        # Extract numeric state - look for INTEGER: value or plain number
        if value.startswith("INTEGER: "):
            state_value = value[9:].strip()
        else:
            # Try to extract number
            v = value.strip()
            # Remove quotes if present
            if v.startswith('"') and v.endswith('"'):
                v = v[1:-1]
            if v.isdigit():
                state_value = v
            elif v.startswith("INTEGER: ") and v[9:].strip().isdigit():
                state_value = v[9:].strip()
    
    if state_value == "":
        return {
            "changed": False,
            "msg": "agent session not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if not state_value.isdigit():
        return {
            "changed": False,
            "msg": "invalid state value: " + state_value,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state_str = str(int(state_value))
    if state_str not in map_states:
        return {
            "changed": False,
            "msg": "unknown state: " + state_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state, readable = map_states[state_str]
    return {
        "changed": False,
        "msg": "Status: " + readable,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
