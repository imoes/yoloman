def main(ctx, params):
    # SNMP base OID and the list of label/value OID pairs from the plugin
    base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    oid_labels = [
        "10.1.2.1.4123",  # System Status label
        "20.1.2.1.4123",  # System Status value
        "10.1.2.1.4240",  # System Model Number label
        "20.1.2.1.4240",  # System Model Number value
        "10.1.2.1.4706",  # Unit Operating State label
        "20.1.2.1.4706",  # Unit Operating State value
        "10.1.2.1.5074",  # Unit Operating State Reason label
        "20.1.2.1.5074",  # Unit Operating State Reason value
    ]

    # Build the full OID list for snmpwalk
    oids = [base_oid + "." + oid for oid in oid_labels]

    # Probe SNMP data
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost")] + oids, mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse snmpwalk output: each line is "OID = TYPE: value"
    # Group label/value pairs by their base label OID
    entries = {}
    current_label = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Split on " = "
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        full_oid, value_part = parts
        # Strip leading base OID and trailing OID suffixes to get label index
        # We only need to group consecutive label/value pairs
        if full_oid.endswith(".4123"):
            current_label = full_oid
            entries[current_label] = {"label": "", "value": ""}
        elif full_oid.endswith(".4240"):
            current_label = full_oid
            entries[current_label] = {"label": "", "value": ""}
        elif full_oid.endswith(".4706"):
            current_label = full_oid
            entries[current_label] = {"label": "", "value": ""}
        elif full_oid.endswith(".5074"):
            current_label = full_oid
            entries[current_label] = {"label": "", "value": ""}
        else:
            # This shouldn't happen for our known OIDs, but handle gracefully
            continue

        # Extract value after 'TYPE: ' (e.g., "STRING: Normal Operation" -> "Normal Operation")
        value_str = value_part
        if ": " in value_str:
            value_str = value_str.split(": ", 1)[1]
        # Remove surrounding quotes if present (common in SNMP strings)
        if value_str.startswith('"') and value_str.endswith('"'):
            value_str = value_str[1:-1]

        # Map OID suffix to label/value field
        if full_oid.endswith(".4123") or full_oid.endswith(".4240") or full_oid.endswith(".4706") or full_oid.endswith(".5074"):
            # Odd OID (label)
            entries[full_oid]["label"] = value_str
        else:
            # Even OID (value) - this logic won't work directly, so restructure:
            pass

    # Better parsing: iterate lines and pair them based on label/value OID positions
    lines = res.stdout.splitlines()
    section = {}
    i = 0
    while i + 1 < len(lines):
        label_line = lines[i].strip()
        value_line = lines[i + 1].strip()
        # Check if they match expected label/value OID patterns
        label_base = label_line.split(" = ")[0].rstrip(".")
        value_base = value_line.split(" = ")[0].rstrip(".")

        # Extract OID suffixes (last components)
        label_oid = label_base.split(".")[-1] if "." in label_base else ""
        value_oid = value_base.split(".")[-1] if "." in value_base else ""

        # Match pairs based on label/value OID patterns: 10.XX.1.2.1.label_idx -> 20.XX.1.2.1.label_idx
        # We only need the label_idx to pair (e.g., 4123, 4240, etc.)
        if label_oid == "10.1.2.1.4123" and value_oid == "20.1.2.1.4123":
            label_name = "System Status"
            value_str = value_line.split(" = ", 1)[1]
            if ": " in value_str:
                value_str = value_str.split(": ", 1)[1]
            if value_str.startswith('"') and value_str.endswith('"'):
                value_str = value_str[1:-1]
            section[label_name] = value_str
            i += 2
        elif label_oid == "10.1.2.1.4240" and value_oid == "20.1.2.1.4240":
            label_name = "System Model Number"
            value_str = value_line.split(" = ", 1)[1]
            if ": " in value_str:
                value_str = value_str.split(": ", 1)[1]
            if value_str.startswith('"') and value_str.endswith('"'):
                value_str = value_str[1:-1]
            section[label_name] = value_str
            i += 2
        elif label_oid == "10.1.2.1.4706" and value_oid == "20.1.2.1.4706":
            label_name = "Unit Operating State"
            value_str = value_line.split(" = ", 1)[1]
            if ": " in value_str:
                value_str = value_str.split(": ", 1)[1]
            if value_str.startswith('"') and value_str.endswith('"'):
                value_str = value_str[1:-1]
            section[label_name] = value_str
            i += 2
        elif label_oid == "10.1.2.1.5074" and value_oid == "20.1.2.1.5074":
            label_name = "Unit Operating State Reason"
            value_str = value_line.split(" = ", 1)[1]
            if ": " in value_str:
                value_str = value_str.split(": ", 1)[1]
            if value_str.startswith('"') and value_str.endswith('"'):
                value_str = value_str[1:-1]
            section[label_name] = value_str
            i += 2
        else:
            # Skip mismatched or unknown lines
            i += 1

    # Discovery mode
    if params.get("_discover"):
        model = section.get("System Model Number", "")
        if model:
            return {"changed": False, "msg": "discovered 1 system",
                    "data": {"discovery": [{"item": model, "params": {}, "metrics": []}]}}
        return {"changed": False, "msg": "no system found", "data": {"discovery": []}}

    # Check mode
    item = params.get("item", "")
    # Use item to select model (only one item expected)
    model = section.get("System Model Number", "")
    if model == "":
        return {"changed": False, "msg": "no system data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Check logic: CRIT if any key is not "Normal Operation", else OK
    state = "OK"
    details_parts = []
    for key, value in sorted(section.items()):
        summary = "%s: %s" % (key, value)
        details_parts.append(summary)
        if key == "System Status" and "Normal Operation" not in value:
            state = "CRIT"

    msg = "Status: " + (section.get("System Status", "unknown") or "unknown")
    if state == "CRIT":
        msg = "CRIT: " + msg
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": "; ".join(details_parts)}}