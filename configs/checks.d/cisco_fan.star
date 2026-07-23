# ===== module-level constants =====
CISCO_FAN_STATE_MAPPING = {
    "1": ("OK", "normal"),
    "2": ("WARN", "warning"),
    "3": ("CRIT", "critical"),
    "4": ("CRIT", "shutdown"),
    "5": ("UNKNOWN", "not present"),
    "6": ("CRIT", "not functioning"),
}

# ===== helper functions =====
def cisco_sensor_item(description, sensor_id):
    # Guard: if description is empty, use sensor_id
    if description == "":
        return sensor_id
    
    # Split by comma - guard against failure
    splitted = []
    parts = description.split(",")
    for part in parts:
        stripped = part.strip()
        if stripped != "":
            splitted.append(stripped)
    
    if len(splitted) == 0:
        return sensor_id
    
    item = ""
    if len(splitted) == 1:
        item = description
    elif ("#" in splitted[-1]) or ("Power" in splitted[-1]):
        item = " ".join(splitted)
    elif splitted[-1].startswith("PS"):
        item = " ".join([splitted[0], splitted[-1].split(" ")[0]])
    elif (len(splitted) >= 2) and (splitted[-2].startswith("PS")):
        parts = splitted[-2].split(" ")
        item = " ".join(splitted[:-2] + parts[:-1])
    elif (len(splitted) >= 2) and (splitted[-2].startswith("Status")):
        item = " ".join(splitted[:-2])
    else:
        item = " ".join(splitted[:-1])

    # Different sensors may have identical descriptions. To prevent
    # duplicate items the sensor_id is appended.
    if len(item) > 0 and (not item[-1].isdigit()):
        item += " " + sensor_id

    return item.replace("#", " ")

# ===== main module entry =====
def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk SNMP for Cisco FAN data
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.9.9.13.1.4.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}

        # Parse snmpwalk output
        items = []
        lines = res.stdout.splitlines()
        # Create arrays for each OID type
        descriptions = {}
        states = {}
        sensor_ids = {}
        
        for line in lines:
            if line == "":
                continue
            # Split OID and value
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_part, val_part = parts
            # Extract index from OID
            oid_parts = oid_part.split(".")
            if len(oid_parts) < 10:
                continue
            idx = oid_parts[-1]
            
            # Determine which OID this is
            oid_suffix = oid_parts[-2]  # 2, 3, or 4
            val = ""
            if ": " in val_part:
                val = val_part.split(": ", 1)[-1]
            else:
                val = val_part
            
            if oid_suffix == "2":
                descriptions[idx] = val.strip('"')
            elif oid_suffix == "3":
                # INTEGER: strip "INTEGER: " prefix
                if val.startswith("INTEGER: "):
                    states[idx] = val[9:]
                else:
                    states[idx] = val
            elif oid_suffix == "4":
                if val.startswith("INTEGER: "):
                    sensor_ids[idx] = val[9:]
                else:
                    sensor_ids[idx] = val
        
        # Now iterate through all indices that have both description and state
        for idx in descriptions:
            if (not idx in states) or (not idx in sensor_ids):
                continue
            state_val = states[idx]
            # Only discover if state is in the list of actionable states
            if state_val in ["1", "2", "3", "4", "6"]:
                item = cisco_sensor_item(descriptions.get(idx, ""), sensor_ids.get(idx, idx))
                items.append({"item": item, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d fans" % len(items),
                "data": {"discovery": items}}

    # Check mode: examine one item
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.9.9.13.1.4.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the output to find the matching item
    lines = res.stdout.splitlines()
    descriptions = {}
    states = {}
    sensor_ids = {}
    
    for line in lines:
        if line == "":
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_part, val_part = parts
        oid_parts = oid_part.split(".")
        if len(oid_parts) < 10:
            continue
        idx = oid_parts[-1]
        oid_suffix = oid_parts[-2]
        val = ""
        if ": " in val_part:
            val = val_part.split(": ", 1)[-1]
        else:
            val = val_part
        
        if oid_suffix == "2":
            descriptions[idx] = val.strip('"')
        elif oid_suffix == "3":
            if val.startswith("INTEGER: "):
                states[idx] = val[9:]
            else:
                states[idx] = val
        elif oid_suffix == "4":
            if val.startswith("INTEGER: "):
                sensor_ids[idx] = val[9:]
            else:
                sensor_ids[idx] = val
    
    # Now search for matching item
    for idx in descriptions:
        if not idx in states:
            continue
        state_val = states[idx]
        # Only check actionable states
        if state_val not in ["1", "2", "3", "4", "6"]:
            continue
        current_item = cisco_sensor_item(descriptions.get(idx, ""), sensor_ids.get(idx, idx))
        if current_item == item:
            # Found the item; get state mapping
            state_readable = CISCO_FAN_STATE_MAPPING.get(state_val, ("UNKNOWN", "unknown[%s]" % state_val))
            state_str, readable = state_readable
            return {
                "changed": False,
                "msg": "Status: " + readable,
                "data": {
                    "state": state_str,
                    "metrics": {},
                    "details": "",
                },
            }

    # Item not found
    return {"changed": False, "msg": "fan not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
