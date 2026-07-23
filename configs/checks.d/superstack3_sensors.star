def main(ctx, params):
    # Read-only SNMP-based check for SuperStack 3 sensors
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode: enumerate all sensors (items) present on host
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.43.43.1.1.7"
        ], mutates=False)
        # Also fetch corresponding .10 (sensor state) values to filter "not present"
        state_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.43.43.1.1.10"
        ], mutates=False)

        # Parse snmpwalk output: "<oid> = STRING: \"value\""
        # Build mapping: index -> (name, state) from OID suffix
        names = {}
        states = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, val_part = parts
            # Extract numeric suffix: .1.3.6.1.4.1.43.43.1.1.7.123 -> 123
            suffix = oid_part.rsplit(".", 1)[-1]
            # Strip quotes and whitespace from value
            val = val_part.strip()
            if val.startswith("STRING: "):
                val = val[8:].strip().strip('"')
            names[suffix] = val

        for line in state_res.stdout.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, val_part = parts
            suffix = oid_part.rsplit(".", 1)[-1]
            val = val_part.strip()
            if val.startswith("STRING: "):
                val = val[8:].strip().strip('"')
            states[suffix] = val

        # Build list of items: only if state != "not present"
        items = []
        for suffix in names:
            if suffix in states and states[suffix] != "not present":
                item_name = names[suffix]
                items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: verify one sensor item
    item = params.get("item", "")

    # Fetch sensor name and state via snmpget for performance
    # First get sensor name list (to validate)
    # Since we already have the item, just fetch the corresponding state OID
    # OID for sensor state at index i: .1.3.6.1.4.1.43.43.1.1.10.i
    # But we don't know the index from item name directly; instead fetch full table
    # Using snmpwalk for state OID is acceptable for a single item check
    state_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.43.43.1.1.10"
    ], mutates=False)

    # Build mapping of name -> state
    name_to_state = {}
    for line in state_res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, val_part = parts
        # Extract numeric index from OID suffix
        suffix = oid_part.rsplit(".", 1)[-1]
        val = val_part.strip()
        if val.startswith("STRING: "):
            val = val[8:].strip().strip('"')
        # We need to map name -> state, but we don't have name here
        # Instead, fetch sensor names in parallel
        pass

    # Re-fetch names to match by index
    name_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.43.43.1.1.7"
    ], mutates=False)

    # Parse both tables and build mapping
    names_list = []
    states_list = []

    for line in name_res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, val_part = parts
        suffix = oid_part.rsplit(".", 1)[-1]
        val = val_part.strip()
        if val.startswith("STRING: "):
            val = val[8:].strip().strip('"')
        names_list.append((suffix, val))

    for line in state_res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, val_part = parts
        suffix = oid_part.rsplit(".", 1)[-1]
        val = val_part.strip()
        if val.startswith("STRING: "):
            val = val[8:].strip().strip('"')
        states_list.append((suffix, val))

    # Build name->state map (index alignment is assumed)
    name_to_state = {}
    state_by_index = dict(states_list)
    for suffix, name in names_list:
        if suffix in state_by_index:
            state = state_by_index[suffix]
            if state != "not present":
                name_to_state[name] = state

    # Look for the requested item
    if item not in name_to_state:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state = name_to_state[item]
    if state == "failure":
        state_out = "CRIT"
        msg = "status is failure"
    elif state == "operational":
        state_out = "OK"
        msg = "status is operational"
    else:
        state_out = "WARN"
        msg = "status is " + state

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state_out, "metrics": {}, "details": ""}
    }