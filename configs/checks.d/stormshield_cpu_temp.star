def main(ctx, params):
    # SNMP base OID for stormshield CPU temp
    base_oid = ".1.3.6.1.4.1.11256.1.10.7.1"
    index_oid = base_oid + ".1"
    temp_oid = base_oid + ".2"

    if params.get("_discover"):
        # Discovery mode: walk the temperature index OID and enumerate items
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), index_oid
        ], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) >= 2:
                # OID format: .1.3.6.1.4.1.11256.1.10.7.1.1.<index> = INTEGER: <index>
                oid_part = parts[0]
                # Extract last component (the index)
                last_part = oid_part.rsplit(".", 1)[-1]
                # Guard instead of try/except
                if last_part.isdigit():
                    idx = str(int(last_part))
                    items.append({
                        "item": idx,
                        "params": {},
                        "metrics": ["temp"]
                    })
        return {
            "changed": False,
            "msg": "discovered %d CPU sensors" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: get temp for specific item
    item = params.get("item", "")

    # Fetch both index and temp OID values
    index_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), index_oid
    ], mutates=False)
    temp_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), temp_oid
    ], mutates=False)

    # Build index-to-temp map
    index_to_temp = {}
    index_lines = index_res.stdout.splitlines()
    temp_lines = temp_res.stdout.splitlines()

    # Match by position since snmpwalk order is consistent
    for idx_line, temp_line in zip(index_lines, temp_lines):
        # Parse index line: ".1.3.6.1.4.1.11256.1.10.7.1.1.<idx> = INTEGER: <value>"
        # Parse temp line: ".1.3.6.1.4.1.11256.1.10.7.1.2.<idx> = INTEGER: <value>"
        # Extract temp value (second part after =, strip trailing spaces)
        if idx_line.strip() == "" or temp_line.strip() == "":
            continue

        idx_parts = idx_line.strip().split()
        temp_parts = temp_line.strip().split()

        if len(idx_parts) >= 4 and len(temp_parts) >= 4:
            # Extract index number from OID
            oid_full = idx_parts[0]
            last_seg = oid_full.rsplit(".", 1)[-1]
            # Guard instead of try/except
            if last_seg.isdigit():
                idx_val = str(int(last_seg))
                # Extract temperature value (after "INTEGER: " or "INTEGER:")
                temp_str = " ".join(temp_parts[3:]).strip().rstrip()
                # Guard: ensure temp_str is a valid number string
                # Allow decimal point
                temp_str_clean = temp_str.replace(".", "", 1)
                if temp_str_clean.isdigit() or (temp_str[0] == "-" and temp_str[1:].replace(".", "", 1).isdigit()):
                    temp_val = float(temp_str)
                    index_to_temp[idx_val] = temp_val

    # Find matching temperature for item
    if item not in index_to_temp:
        return {
            "changed": False,
            "msg": "sensor %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    temp = index_to_temp[item]

    # Apply temperature check logic (simplified check_temperature equivalent)
    # Default thresholds: warn=70°C, crit=80°C (common CPU thresholds)
    warn = params.get("levels", (70.0, 80.0))
    if type(warn) == "list" or type(warn) == "tuple":
        warn_val = float(warn[0])
        crit_val = float(warn[1])
    else:
        warn_val = 70.0
        crit_val = 80.0

    # Determine state
    state = "OK"
    if temp >= crit_val:
        state = "CRIT"
    elif temp >= warn_val:
        state = "WARN"

    # Format message
    msg = "Temperature: %f°C" % temp

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": temp},
            "details": ""
        }
    }