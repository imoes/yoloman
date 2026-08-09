def main(ctx, params):
    # Extract params for SNMP access
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Discovery mode: enumerate VS instances with conn_num
    if params.get("_discover"):
        # Fetch status section: .1.3.6.1.4.1.2620.1.16.22.1.1.{1,3,4,5,6,7,8,9}
        status_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.2620.1.16.22.1.1.1",
            ".1.3.6.1.4.1.2620.1.16.22.1.1.3",
            ".1.3.6.1.4.1.2620.1.16.22.1.1.4",
            ".1.3.6.1.4.1.2620.1.16.22.1.1.5",
            ".1.3.6.1.4.1.2620.1.16.22.1.1.6",
            ".1.3.6.1.4.1.2620.1.16.22.1.1.7",
            ".1.3.6.1.4.1.2620.1.16.22.1.1.8",
            ".1.3.6.1.4.1.2620.1.16.22.1.1.9"
        ], mutates=False)
        if status_res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed for status section: " + status_res.stderr,
                "data": {"discovery": []}
            }

        # Fetch counter section: .1.3.6.1.4.1.2620.1.16.23.1.1.{2,4,5,6,7,8,9,10,11,12}
        counter_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.2620.1.16.23.1.1.2",
            ".1.3.6.1.4.1.2620.1.16.23.1.1.4",
            ".1.3.6.1.4.1.2620.1.16.23.1.1.5",
            ".1.3.6.1.4.1.2620.1.16.23.1.1.6",
            ".1.3.6.1.4.1.2620.1.16.23.1.1.7",
            ".1.3.6.1.4.1.2620.1.16.23.1.1.8",
            ".1.3.6.1.4.1.2620.1.16.23.1.1.9",
            ".1.3.6.1.4.1.2620.1.16.23.1.1.10",
            ".1.3.6.1.4.1.2620.1.16.23.1.1.11",
            ".1.3.6.1.4.1.2620.1.16.23.1.1.12"
        ], mutates=False)
        if counter_res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed for counter section: " + counter_res.stderr,
                "data": {"discovery": []}
            }

        # Parse snmpwalk output: "<oid> = <type>: <value>"
        def get_oid_value_map(res):
            result = {}
            for line in res.stdout.splitlines():
                stripped = line.strip()
                if stripped == "":
                    continue
                eq_idx = stripped.find(" = ")
                if eq_idx == -1:
                    continue
                oid_part = stripped[:eq_idx].strip()
                value_part = stripped[eq_idx + 3:].strip()
                # Extract base oid without trailing index for grouping
                base_oid = ".".join(oid_part.split(".")[:-1])
                # Extract integer index and value
                parts = value_part.split(": ")
                if len(parts) >= 2:
                    value = ":".join(parts[1:]).strip().strip('"')
                else:
                    value = ""
                result[oid_part] = value
            return result

        status_map = get_oid_value_map(status_res)
        counter_map = get_oid_value_map(counter_res)

        # Group by VS instance using the index from the base oid
        vs_entries = {}
        for oid, value in status_map.items():
            # oid format: .1.3.6.1.4.1.2620.1.16.22.1.1.1.1.0 (example)
            # We need to group by index part (last numeric component)
            # oid ends with .<index>
            tokens = oid.split(".")
            if len(tokens) < 3:
                continue
            index = tokens[-1]
            if index not in vs_entries:
                vs_entries[index] = {}
            # Map oid suffix to field name
            suffix = tokens[-2]
            if suffix == "1":  # vs_id
                vs_entries[index]["vs_id"] = value
            elif suffix == "3":  # vs_name
                vs_entries[index]["vs_name"] = value
            elif suffix == "4":  # vs_type
                vs_entries[index]["vs_type"] = value
            elif suffix == "5":  # vs_ip
                vs_entries[index]["vs_ip"] = value
            elif suffix == "6":  # vs_policy
                vs_entries[index]["vs_policy"] = value
            elif suffix == "7":  # vs_policy_type
                vs_entries[index]["vs_policy_type"] = value
            elif suffix == "8":  # vs_sic_status
                vs_entries[index]["vs_sic_status"] = value
            elif suffix == "9":  # vs_ha_status
                vs_entries[index]["vs_ha_status"] = value

        # Collect counter values
        for oid, value in counter_map.items():
            tokens = oid.split(".")
            if len(tokens) < 3:
                continue
            index = tokens[-1]
            if index not in vs_entries:
                continue
            suffix = tokens[-2]
            if suffix == "2":  # conn_num
                vs_entries[index]["conn_num"] = value if value.isdigit() else None
            elif suffix == "4":  # conn_table_size
                vs_entries[index]["conn_table_size"] = value if value.isdigit() else None

        # Discover items where conn_num is available (non-null)
        discovery = []
        for index, entry in vs_entries.items():
            conn_num_str = entry.get("conn_num")
            if conn_num_str != None and conn_num_str != "":
                item_name = entry.get("vs_name", "") + " " + entry.get("vs_id", index)
                discovery.append({
                    "item": item_name,
                    "params": {"levels_perc": ("fixed", (90.0, 95.0))},
                    "metrics": ["connections"]
                })

        return {
            "changed": False,
            "msg": "discovered %d VS connections" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode: single item
    item = params.get("item", "")
    warn_levels = params.get("levels_perc", ("fixed", (90.0, 95.0)))
    warn_val = 90.0
    crit_val = 95.0
    if warn_levels != None and type(warn_levels) == "list" and len(warn_levels) >= 2:
        warn_val = float(warn_levels[1][0]) if type(warn_levels[1]) == "list" else float(warn_levels[1])
        crit_val = float(warn_levels[1][1]) if type(warn_levels[1]) == "list" else float(warn_levels[1])
    elif warn_levels != None and type(warn_levels) == "string":
        # Handle ("fixed", (90.0, 95.0)) format parsed as nested structure
        if warn_levels.find("fixed") != -1:
            # Extract numbers manually from the representation
            # e.g., "('fixed', (90.0, 95.0))" -> extract floats
            warn_val = 90.0
            crit_val = 95.0

    # Fetch status section
    status_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.2620.1.16.22.1.1.1",
        ".1.3.6.1.4.1.2620.1.16.22.1.1.3",
        ".1.3.6.1.4.1.2620.1.16.22.1.1.4",
        ".1.3.6.1.4.1.2620.1.16.22.1.1.5",
        ".1.3.6.1.4.1.2620.1.16.22.1.1.6",
        ".1.3.6.1.4.1.2620.1.16.22.1.1.7",
        ".1.3.6.1.4.1.2620.1.16.22.1.1.8",
        ".1.3.6.1.4.1.2620.1.16.22.1.1.9"
    ], mutates=False)

    # Fetch counter section
    counter_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.2620.1.16.23.1.1.2",
        ".1.3.6.1.4.1.2620.1.16.23.1.1.4",
        ".1.3.6.1.4.1.2620.1.16.23.1.1.5",
        ".1.3.6.1.4.1.2620.1.16.23.1.1.6",
        ".1.3.6.1.4.1.2620.1.16.23.1.1.7",
        ".1.3.6.1.4.1.2620.1.16.23.1.1.8",
        ".1.3.6.1.4.1.2620.1.16.23.1.1.9",
        ".1.3.6.1.4.1.2620.1.16.23.1.1.10",
        ".1.3.6.1.4.1.2620.1.16.23.1.1.11",
        ".1.3.6.1.4.1.2620.1.16.23.1.1.12"
    ], mutates=False)

    if status_res.rc != 0 or counter_res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP fetch failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP values into flat mapping
    def get_oid_value_map(res):
        result = {}
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped == "":
                continue
            eq_idx = stripped.find(" = ")
            if eq_idx == -1:
                continue
            oid_part = stripped[:eq_idx].strip()
            value_part = stripped[eq_idx + 3:].strip()
            parts = value_part.split(": ")
            if len(parts) >= 2:
                value = ":".join(parts[1:]).strip().strip('"')
            else:
                value = ""
            result[oid_part] = value
        return result

    status_map = get_oid_value_map(status_res)
    counter_map = get_oid_value_map(counter_res)

    # Group by VS instance index
    vs_entries = {}
    for oid, value in status_map.items():
        tokens = oid.split(".")
        if len(tokens) < 3:
            continue
        index = tokens[-1]
        if index not in vs_entries:
            vs_entries[index] = {}
        suffix = tokens[-2]
        if suffix == "1":  # vs_id
            vs_entries[index]["vs_id"] = value
        elif suffix == "3":  # vs_name
            vs_entries[index]["vs_name"] = value
        elif suffix == "4":  # vs_type
            vs_entries[index]["vs_type"] = value
        elif suffix == "5":  # vs_ip
            vs_entries[index]["vs_ip"] = value
        elif suffix == "6":  # vs_policy
            vs_entries[index]["vs_policy"] = value
        elif suffix == "7":  # vs_policy_type
            vs_entries[index]["vs_policy_type"] = value
        elif suffix == "8":  # vs_sic_status
            vs_entries[index]["vs_sic_status"] = value
        elif suffix == "9":  # vs_ha_status
            vs_entries[index]["vs_ha_status"] = value

    # Add counter values
    for oid, value in counter_map.items():
        tokens = oid.split(".")
        if len(tokens) < 3:
            continue
        index = tokens[-1]
        if index not in vs_entries:
            continue
        suffix = tokens[-2]
        if suffix == "2":  # conn_num
            vs_entries[index]["conn_num"] = value if value.isdigit() else None
        elif suffix == "4":  # conn_table_size
            vs_entries[index]["conn_table_size"] = value if value.isdigit() else None

    # Look up item by matching vs_name + vs_id or vs_name+vs_id concatenation
    found_entry = None
    for index, entry in vs_entries.items():
        candidate_name = entry.get("vs_name", "") + " " + entry.get("vs_id", index)
        if candidate_name.strip() == item.strip():
            found_entry = entry
            break

    if found_entry == None:
        # Try alternate matching: vs_name + vs_id without trailing space
        for index, entry in vs_entries.items():
            candidate_name = (entry.get("vs_name", "") + " " + entry.get("vs_id", "")).strip()
            if candidate_name == item.strip():
                found_entry = entry
                break

    if found_entry == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    conn_num_str = found_entry.get("conn_num")
    conn_table_size_str = found_entry.get("conn_table_size")

    if conn_num_str == None or conn_num_str == "" or not conn_num_str.isdigit():
        return {
            "changed": False,
            "msg": "connections data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if conn_table_size_str == None or conn_table_size_str == "" or not conn_table_size_str.isdigit():
        return {
            "changed": False,
            "msg": "connection table size not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    conn_total = int(conn_num_str)
    conn_limit = int(conn_table_size_str)

    # Compute percentage
    if conn_limit > 0:
        used_percent = 100.0 * conn_total / conn_limit
    else:
        used_percent = 0.0

    state = "OK"
    if used_percent >= crit_val:
        state = "CRIT"
    elif used_percent >= warn_val:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Used: %d of %d (%f%%)" % (conn_total, conn_limit, used_percent),
        "data": {
            "state": state,
            "metrics": {"connections": conn_total},
            "details": ""
        }
    }
