def main(ctx, params):
    # SNMP OIDs for juniper_trpz_power
    BASE_OID = ".1.3.6.1.4.1.14525.4.8.1.1.13.1.2.1"
    OID_PSU_NAME = BASE_OID + ".3"
    OID_PSU_STATE = BASE_OID + ".2"

    # State mapping
    STATES = {
        1: "other",
        2: "unknown",
        3: "ac-failed",
        4: "dc-failed",
        5: "ac-ok-dc-ok",
    }

    # Detect Juniper TRPZ device (same detection logic as Checkmk source)
    # .1.3.6.1.2.1.1.2.0 = sysObjectID.0
    res_detect = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
                         mutates=False)
    if res_detect.rc != 0 or res_detect.stdout == "":
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract sysObjectID value
    parts = res_detect.stdout.strip().split(" = ")
    if len(parts) != 2:
        return {"changed": False, "msg": "could not parse sysObjectID",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    sys_object_id = parts[1].strip()
    
    # Check if device matches Juniper TRPZ (starts with .1.3.6.1.4.1.14525.3)
    if not sys_object_id.startswith(".1.3.6.1.4.1.14525.3"):
        return {"changed": False, "msg": "not a Juniper TRPZ device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        # Discovery mode: walk PSU OIDs
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), OID_PSU_NAME],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}

        items = []
        for line in res.stdout.splitlines():
            if not line:
                continue
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            # Extract item name from OID leaf (e.g., ".1.3.6.1.4.1.14525.4.8.1.1.13.1.2.1.3.1 = STRING: "PSU 1"")
            # Parse the leaf index (last number) as item name (like Checkmk does)
            oid_path = parts[0].rstrip(":")
            # Get last OID component as index
            index = oid_path.split(".")[-1]
            if not index.isdigit():
                continue
            
            # Get the value
            value_part = " ".join(parts[2:])
            # Remove quotes from STRING type
            if value_part.startswith('"') and value_part.endswith('"'):
                value_part = value_part[1:-1]
            elif value_part.startswith('STRING: "'):
                value_part = value_part[8:-1]
            
            # Store item with index (as string) as item name
            items.append({"item": index, "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d PSUs" % len(items),
                "data": {"discovery": items}}

    # Check mode: specific item
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch both OID values for the given item index
    res_name = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                        "-On", params.get("host", "localhost"), OID_PSU_NAME + "." + item],
                       mutates=False)
    res_state = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), OID_PSU_STATE + "." + item],
                        mutates=False)

    # Parse state
    if res_state.rc != 0:
        return {"changed": False, "msg": "could not retrieve PSU state for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract state value
    state_line = res_state.stdout.strip()
    parts = state_line.split(" = ")
    if len(parts) != 2:
        return {"changed": False, "msg": "could not parse PSU state",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_val_str = parts[1].strip()
    # Extract numeric value (handles INTEGER:, gauge32:, etc.)
    if ":" in state_val_str:
        state_val_str = state_val_str.split(":")[-1].strip()
    
    # Convert to int
    if not state_val_str.isdigit():
        return {"changed": False, "msg": "invalid state value: " + state_val_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state_val = int(state_val_str)

    # Determine status
    state_name = STATES.get(state_val, "unknown-state-%d" % state_val)
    msg = "Current state: %s" % state_name
    
    # Determine state severity
    if state_val in [2, 3, 4]:
        status = "CRIT"
    elif state_val == 1:
        status = "WARN"
    else:
        status = "OK"

    return {"changed": False, "msg": msg,
            "data": {"state": status, "metrics": {}, "details": ""}}