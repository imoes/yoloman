def main(ctx, params):
    # Checkmk check: checkpoint_vsx
    # Read-only Starlark translation: gather data via SNMP, parse, and report
    # No mutates=True, no file writes — pure info reporting

    # Determine mode
    if params.get("_discover"):
        # DISCOVERY MODE: walk the status table to enumerate items
        # SNMPTree base=".1.3.6.1.4.1.2620.1.16.22.1.1", oids=["1","3","4","5","6","7","8","9"]
        # We need to fetch both tables: status and counter
        # For simplicity, walk both trees separately and pair by index (reversed in original)
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # Fetch status table: VS_ID, VS_NAME, VS_TYPE, VS_IP, VS_POLICY, VS_POLICY_TYPE, VS_SIC_STATUS, VS_HA_STATUS
        res_status = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.2620.1.16.22.1.1"
        ], mutates=False)
        if res_status.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed for status tree: " + res_status.stderr,
                "data": {"discovery": []},
            }

        # Parse status lines: format is ".oid.index = TYPE: value"
        status_entries = {}
        for line in res_status.stdout.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value_raw = parts[1].strip()
            # Extract last component (index) and oid base
            last_dot = oid_full.rfind(".")
            if last_dot < 0:
                continue
            index = oid_full[last_dot+1:]
            oid_base = oid_full[:last_dot]
            if oid_base in status_entries:
                status_entries[oid_base][index] = value_raw
            else:
                status_entries[oid_base] = {index: value_raw}

        # Fetch counter table: conn_table_size(2), conn_num(4), packets(5), packets_dropped(6),
        # packets_accepted(7), packets_rejected(8), bytes_accepted(9), bytes_dropped(10),
        # bytes_rejected(11), packets_logged(12)
        res_counter = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.2620.1.16.23.1.1"
        ], mutates=False)
        if res_counter.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed for counter tree: " + res_counter.stderr,
                "data": {"discovery": []},
            }

        counter_entries = {}
        for line in res_counter.stdout.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value_raw = parts[1].strip()
            last_dot = oid_full.rfind(".")
            if last_dot < 0:
                continue
            index = oid_full[last_dot+1:]
            oid_base = oid_full[:last_dot]
            if oid_base in counter_entries:
                counter_entries[oid_base][index] = value_raw
            else:
                counter_entries[oid_base] = {index: value_raw}

        # Build item list from status table (reversed pairing in original, but discovery yields all items)
        # We need to pair status and counter data by index (reversed order, but discovery yields all items)
        # For simplicity, collect all unique indexes from status table
        indexes = set()
        for oid_base, data in status_entries.items():
            for idx in data:
                indexes.add(idx)

        discovery_list = []
        for idx in sorted(indexes):
            # Extract fields from status_entries
            # oid 1=vs_id, 3=vs_name, 4=vs_type, 5=vs_ip, 6=vs_policy, 7=vs_policy_type, 8=vs_sic_status, 9=vs_ha_status
            vs_id = status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.1", {}).get(idx, "")
            vs_name = status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.3", {}).get(idx, "")
            vs_type = status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.4", {}).get(idx, "")
            vs_ip = status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.5", {}).get(idx, "")
            vs_policy = status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.6", {}).get(idx, "")
            vs_policy_type = status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.7", {}).get(idx, "")
            vs_sic_status = status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.8", {}).get(idx, "")
            vs_ha_status = status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.9", {}).get(idx, "")

            # Trim quotes if present
            def _trim(s):
                if s.startswith('"') and s.endswith('"'):
                    return s[1:-1]
                return s
            vs_name = _trim(vs_name)
            vs_type = _trim(vs_type)
            vs_ip = _trim(vs_ip)
            vs_policy = _trim(vs_policy)
            vs_policy_type = _trim(vs_policy_type)
            vs_sic_status = _trim(vs_sic_status)
            vs_ha_status = _trim(vs_ha_status)

            # Item name is "VS_NAME VS_ID"
            item = vs_name + " " + vs_id
            discovery_list.append({
                "item": item,
                "params": {},
                "metrics": ["connections", "packets", "packets_accepted", "packets_dropped",
                            "packets_rejected", "packets_logged", "bytes_accepted",
                            "bytes_dropped", "bytes_rejected"]
            })

        return {
            "changed": False,
            "msg": "discovered %d VS instances" % len(discovery_list),
            "data": {"discovery": discovery_list},
        }

    # CHECK MODE
    # item = params.get("item", "")  # item name is "VS_NAME VS_ID"
    # Checkmk service name pattern is "VS %s Info" — so this check plugin is for the info portion only
    # Per source, check_checkpoint_vsx(item, section) yields:
    #   - Type
    #   - Main IP

    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Fetch only the needed fields for this item
    # We must parse all to find the matching item, because SNMP walk returns all rows
    res_status = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.2620.1.16.22.1.1"
    ], mutates=False)
    if res_status.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res_status.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse status table
    status_entries = {}
    for line in res_status.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value_raw = parts[1].strip()
        last_dot = oid_full.rfind(".")
        if last_dot < 0:
            continue
        index = oid_full[last_dot+1:]
        oid_base = oid_full[:last_dot]
        if oid_base in status_entries:
            status_entries[oid_base][index] = value_raw
        else:
            status_entries[oid_base] = {index: value_raw}

    # Find matching item
    found = False
    vs_type = ""
    vs_ip = ""
    for idx, name in status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.3", {}).items():
        # Extract vs_id and vs_name, construct item name
        vs_id_raw = status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.1", {}).get(idx, "")
        # Trim quotes
        def _trim(s):
            if s.startswith('"') and s.endswith('"'):
                return s[1:-1]
            return s
        vs_name = _trim(_trim(name))
        vs_id = _trim(vs_id_raw)
        candidate_item = vs_name + " " + vs_id
        if candidate_item == item:
            vs_type = _trim(status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.4", {}).get(idx, ""))
            vs_ip = _trim(status_entries.get(".1.3.6.1.4.1.2620.1.16.22.1.1.5", {}).get(idx, ""))
            found = True
            break

    if not found:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Build summary string: "Type: <vs_type>, Main IP: <vs_ip>"
    summary = "Type: " + vs_type + ", Main IP: " + vs_ip
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }
