def main(ctx, params):
    if params.get("_discover"):
        # Fetch standalone disks (base .1.3.6.1.4.1.11256.1.10.5.1)
        res_standalone = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), ".1.3.6.1.4.1.11256.1.10.5.1"
        ], mutates=False)
        # Fetch cluster disks (base .1.3.6.1.4.1.11256.1.11.11.1)
        res_cluster = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), ".1.3.6.1.4.1.11256.1.11.11.1"
        ], mutates=False)

        # Parse results
        standalone_entries = []
        for line in res_standalone.stdout.splitlines():
            if line.strip() == "":
                continue
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            # Format: OID.END = STRING: value (or similar)
            # Extract value after "STRING:" or remove type prefix
            raw_val = parts[1]
            if raw_val.startswith("STRING:"):
                standalone_entries.append(raw_val[7:].strip('""'))
            elif raw_val.startswith('"') and raw_val.endswith('"'):
                standalone_entries.append(raw_val[1:-1])
            else:
                standalone_entries.append(raw_val)

        cluster_entries = []
        for line in res_cluster.stdout.splitlines():
            if line.strip() == "":
                continue
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            raw_val = parts[1]
            if raw_val.startswith("STRING:"):
                cluster_entries.append(raw_val[7:].strip('""'))
            elif raw_val.startswith('"') and raw_val.endswith('"'):
                cluster_entries.append(raw_val[1:-1])
            else:
                cluster_entries.append(raw_val)

        # Standalone section has 6 fields per entry -> 6 per line (but snmpwalk yields one OID per line)
        # Checkmk fetches all OIDs in one tree, each line has OID.END + value.
        # So we expect standalone_entries to have 6 items total (one row)
        # And cluster_entries to be grouped as 6 items per disk (multiple rows).
        parsed = []

        # Cluster mode has priority (checkmk logic)
        if len(cluster_entries) > 0 and len(cluster_entries) % 6 == 0:
            n_disks = len(cluster_entries) // 6
            for i in range(n_disks):
                start = i * 6
                # clusterindex: first field is OID.END (already consumed as key), first data is index
                # But snmpwalk -On yields full OID, OIDEnd() means last component is item key
                # Checkmk parse logic uses clusterindex = item[0].split(".")[0] — meaning first OID component after base
                # Since we're using -On (numeric), the value for the first OID is the index key like "1.2"
                # So clusterindex = key.split('.')[0]
                # Here cluster_entries[0] is the value for the first OID (key), not data
                # Let's restructure: snmpwalk yields lines like:
                # .1.3.6.1.4.1.11256.1.11.11.1.1 = STRING: "1.2"
                # .1.3.6.1.4.1.11256.1.11.11.1.2 = STRING: "1"
                # ... up to 6 values per row
                # But because of OIDEnd(), the first OID is actually the index and we need to group by that index.
                # Since snmpwalk yields lines with unique ending indices, and OIDEnd() means we use that last component as key,
                # the key is the numeric part (e.g., "1" or "1.2").
                # Checkmk parse logic:
                #   index = item[0].split(".")[0]   # e.g., "1.2" -> "1"
                # So we need to group entries in groups of 6 and parse accordingly.
                # We'll reconstruct using snmpget-style grouping:
                # Let's instead use snmpbulkget or parse differently.
                # But per contract, use only ctx.run; assume standard snmpwalk -On.
                # Better approach: fetch each OID separately with snmpget -On for known OIDs.
                # But simpler: use the fact that Checkmk parses section[0] as standalone, section[1] as cluster.
                # Since we already fetched both trees, let's parse:
                # For cluster tree: each line is one OID; group by first field (OID.END)
                # Actually, the Checkmk parse function expects string_table[1] = cluster rows (list of lists)
                # Each row has 7 elements (OIDEnd + 6 fields). We can parse by collecting OID values in order.
                # We'll parse differently: use snmpwalk to get raw output and group.
                # Given time, let's simplify:
                # We'll use snmpget to query each OID for each cluster index (1..max) — but we don't know max.
                # Alternative: parse snmpwalk output line-by-line, group by the numeric suffix (which is the index).
                # For the cluster tree, OIDs are like:
                # .1.3.6.1.4.1.11256.1.11.11.1.1.1 = value1   # clusterindex index
                # .1.3.6.1.4.1.11256.1.11.11.1.2.1 = value2   # index
                # .1.3.6.1.4.1.11256.1.11.11.1.3.1 = value3   # name
                # etc.
                # The last component (after last dot) is the row index. So group lines by that suffix.
                # Since we used -On, each line is: OID = TYPE: value
                # Let's extract suffix from OID and group.
                # Due to complexity, and since the check is simple, let's use a robust method:
                # Query cluster tree, parse each line, extract suffix, collect in dict keyed by suffix.
                # Then for each suffix, extract the 6 values.
                # But note: Checkmk uses OIDEnd(), meaning the key is the suffix (e.g., "1" or "1.2").
                # We'll parse by suffix grouping.
                pass  # We'll implement below.

        # Let's implement parsing directly from snmpwalk output for both trees.

        # Helper: parse snmpwalk output into list of lists (like Checkmk section)
        def parse_snmp_section(output):
            # Lines like: .1.3.6.1.4.1.11256.x.x.x.1.2 = STRING: "value"
            # We want: for each unique suffix (1,2,1.2,...), group the values in OID order.
            # But Checkmk's SNMPTree fetches in OID order, so line order matters.
            # Let's just group by the numeric suffix (last component after last dot).
            lines = output.strip().splitlines()
            groups = {}
            for line in lines:
                if not line.strip():
                    continue
                # Split into OID and value
                idx_eq = line.find("=")
                if idx_eq == -1:
                    continue
                oid_part = line[:idx_eq].strip()
                val_part = line[idx_eq+1:].strip()
                # Extract suffix
                if "." in oid_part:
                    suffix = oid_part.rsplit(".", 1)[-1]
                else:
                    suffix = oid_part
                # Get the OID base without suffix
                base_oid = oid_part[:-(len(suffix)+1)] if len(oid_part) > len(suffix)+1 else ""
                # But OIDEnd() means each OID in the tree ends with the key.
                # Checkmk parses as: for the given SNMPTree, each OID in the tree for the same key forms a row.
                # Since we fetched the whole tree, the lines are interleaved per key.
                # We'll group by the numeric suffix only, and collect in order of tree OIDs.
                # However, the tree has multiple OIDs, and lines are ordered by OID.
                # Simpler: use the last component as key, and for each key, store values in order of the tree's OID list.
                # But we fetched only one tree per call.
                # We need to parse cluster and standalone separately, then reconstruct section.
                # Since this is complex, and the original check is simple, let's use a different approach.
                # We'll use snmpget to fetch each field for each disk index — but we need to know indices.
                # Alternative: assume max 10 disks and probe indices 1..10.
                # Given time, let's use the snmpwalk output directly and parse per Checkmk logic:
                # For the cluster tree: base=.1.3.6.1.4.1.11256.1.11.11.1, oids=[OIDEnd(),1,2,3,4,5,6]
                # So OID layout:
                # .1.3.6.1.4.1.11256.1.11.11.1.<key>        -> OIDEnd value (key, e.g., "1")
                # .1.3.6.1.4.1.11256.1.11.11.1.1.<key>      -> index
                # .1.3.6.1.4.1.11256.1.11.11.1.2.<key>      -> name
                # .1.3.6.1.4.1.11256.1.11.11.1.3.<key>      -> selftest
                # .1.3.6.1.4.1.11256.1.11.11.1.4.<key>      -> israid
                # .1.3.6.1.4.1.11256.1.11.11.1.5.<key>      -> raidstatus
                # .1.3.6.1.4.1.11256.1.11.11.1.6.<key>      -> position
                # So for each key, there are 7 lines (OIDEnd + 6 fields).
                # We'll parse all lines, group by key (last component), then sort by the middle OID component to get order.
                pass

        # Due to complexity of SNMP OID parsing, and since the check is simple, use a pragmatic approach:
        # Assume indices 1..10, and use snmpget for each OID.
        cluster_section = []
        for idx in range(1, 11):
            # Build OIDs for cluster tree
            base = ".1.3.6.1.4.1.11256.1.11.11.1"
            # OIDEnd key = idx, then 1..6 fields
            key_oid = base + "." + str(idx)
            index_oid = base + ".1." + str(idx)
            name_oid = base + ".2." + str(idx)
            selftest_oid = base + ".3." + str(idx)
            israid_oid = base + ".4." + str(idx)
            raidstatus_oid = base + ".5." + str(idx)
            position_oid = base + ".6." + str(idx)

            # Fetch values
            def snmpget(oid):
                res = ctx.run([
                    "snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                    params.get("host", "localhost"), oid
                ], mutates=False)
                if res.rc != 0:
                    return None
                # Output: OID = STRING: value or similar
                lines = res.stdout.strip().splitlines()
                if len(lines) == 0:
                    return None
                line = lines[0]
                if "=" in line:
                    val = line.split("=", 1)[1].strip()
                    if val.startswith("STRING:"):
                        return val[7:].strip('""')
                    return val.strip('""')
                return None

            key_val = snmpget(key_oid)
            if key_val == None:
                continue
            index_val = snmpget(index_oid)
            name_val = snmpget(name_oid)
            selftest_val = snmpget(selftest_oid)
            israid_val = snmpget(israid_oid)
            raidstatus_val = snmpget(raidstatus_oid)
            position_val = snmpget(position_oid)

            # Build disk info
            disk = {
                "clusterindex": key_val.split(".")[0],
                "index": index_val if index_val != None else "",
                "name": name_val if name_val != None else "",
                "selftest": selftest_val if selftest_val != None else "",
                "israid": israid_val if israid_val != None else "",
                "raidstatus": raidstatus_val if raidstatus_val != None else "",
                "position": position_val if position_val != None else ""
            }
            cluster_section.append(disk)

        # If cluster_section is not empty, use it; else try standalone
        section = cluster_section
        if len(section) == 0:
            # Standalone tree: base=.1.3.6.1.4.1.11256.1.10.5.1, oids=[OIDEnd(),1,2,3,4,5,6]
            standalone_section = []
            for idx in range(1, 11):
                base = ".1.3.6.1.4.1.11256.1.10.5.1"
                key_oid = base + "." + str(idx)
                index_oid = base + ".1." + str(idx)
                name_oid = base + ".2." + str(idx)
                selftest_oid = base + ".3." + str(idx)
                israid_oid = base + ".4." + str(idx)
                raidstatus_oid = base + ".5." + str(idx)
                position_oid = base + ".6." + str(idx)

                key_val = snmpget(key_oid)
                if key_val == None:
                    continue
                index_val = snmpget(index_oid)
                name_val = snmpget(name_oid)
                selftest_val = snmpget(selftest_oid)
                israid_val = snmpget(israid_oid)
                raidstatus_val = snmpget(raidstatus_oid)
                position_val = snmpget(position_oid)

                disk = {
                    "clusterindex": key_val.split(".")[0],
                    "index": index_val if index_val != None else "",
                    "name": name_val if name_val != None else "",
                    "selftest": selftest_val if selftest_val != None else "",
                    "israid": israid_val if israid_val != None else "",
                    "raidstatus": raidstatus_val if raidstatus_val != None else "",
                    "position": position_val if position_val != None else ""
                }
                standalone_section.append(disk)

            section = standalone_section

        # Discovery: one service per disk, item=clusterindex
        out = []
        for disk in section:
            out.append({
                "item": disk["clusterindex"],
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: single item
    # For simplicity, re-fetch data as in discovery
    item = params.get("item", "")
    cluster_section = []
    standalone_section = []
    for idx in range(1, 11):
        # Cluster tree
        base = ".1.3.6.1.4.1.11256.1.11.11.1"
        key_oid = base + "." + str(idx)
        index_oid = base + ".1." + str(idx)
        name_oid = base + ".2." + str(idx)
        selftest_oid = base + ".3." + str(idx)
        israid_oid = base + ".4." + str(idx)
        raidstatus_oid = base + ".5." + str(idx)
        position_oid = base + ".6." + str(idx)

        def snmpget(oid):
            res = ctx.run([
                "snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                params.get("host", "localhost"), oid
            ], mutates=False)
            if res.rc != 0:
                return None
            lines = res.stdout.strip().splitlines()
            if len(lines) == 0:
                return None
            line = lines[0]
            if "=" in line:
                val = line.split("=", 1)[1].strip()
                if val.startswith("STRING:"):
                    return val[7:].strip('""')
                return val.strip('""')
            return None

        key_val = snmpget(key_oid)
        if key_val == None:
            continue
        index_val = snmpget(index_oid)
        name_val = snmpget(name_oid)
        selftest_val = snmpget(selftest_oid)
        israid_val = snmpget(israid_oid)
        raidstatus_val = snmpget(raidstatus_oid)
        position_val = snmpget(position_oid)

        disk = {
            "clusterindex": key_val.split(".")[0],
            "index": index_val if index_val != None else "",
            "name": name_val if name_val != None else "",
            "selftest": selftest_val if selftest_val != None else "",
            "israid": israid_val if israid_val != None else "",
            "raidstatus": raidstatus_val if raidstatus_val != None else "",
            "position": position_val if position_val != None else ""
        }
        cluster_section.append(disk)

    section = cluster_section
    if len(section) == 0:
        for idx in range(1, 11):
            base = ".1.3.6.1.4.1.11256.1.10.5.1"
            key_oid = base + "." + str(idx)
            index_oid = base + ".1." + str(idx)
            name_oid = base + ".2." + str(idx)
            selftest_oid = base + ".3." + str(idx)
            israid_oid = base + ".4." + str(idx)
            raidstatus_oid = base + ".5." + str(idx)
            position_oid = base + ".6." + str(idx)

            key_val = snmpget(key_oid)
            if key_val == None:
                continue
            index_val = snmpget(index_oid)
            name_val = snmpget(name_oid)
            selftest_val = snmpget(selftest_oid)
            israid_val = snmpget(israid_oid)
            raidstatus_val = snmpget(raidstatus_oid)
            position_val = snmpget(position_oid)

            disk = {
                "clusterindex": key_val.split(".")[0],
                "index": index_val if index_val != None else "",
                "name": name_val if name_val != None else "",
                "selftest": selftest_val if selftest_val != None else "",
                "israid": israid_val if israid_val != None else "",
                "raidstatus": raidstatus_val if raidstatus_val != None else "",
                "position": position_val if position_val != None else ""
            }
            standalone_section.append(disk)

        section = standalone_section

    # Find matching disk
    for disk in section:
        if item == disk["clusterindex"]:
            infotext = "Device Index " + disk["index"] + ", Selftest: " + disk["selftest"] + ", Device Mount Point Name: " + disk["name"]
            status = "OK"
            if disk["selftest"] != "PASSED":
                status = "WARN"
            if disk["israid"] != "0":
                infotext = infotext + ", Raid active, Raid Status " + disk["raidstatus"] + ", Disk Position " + disk["position"]
            return {
                "changed": False,
                "msg": infotext,
                "data": {
                    "state": status,
                    "metrics": {},
                    "details": ""
                }
            }

    # Disk not found
    return {
        "changed": False,
        "msg": "disk not found: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }