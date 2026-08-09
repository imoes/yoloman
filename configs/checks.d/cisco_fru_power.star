def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("snmp_version", "2c")
    oid_end = params.get("oid_end", "")
    name = params.get("name", "")

    # Discovery OID base (entity names): .1.3.6.1.2.1.47.1.1.1.1 with OIDEnd + "7"
    name_base = ".1.3.6.1.2.1.47.1.1.1.1"
    name_oid_col = "7"

    # Power states/current base: .1.3.6.1.4.1.9.9.117.1.1.2.1 with OIDEnd + "2" + "3"
    power_base = ".1.3.6.1.4.1.9.9.117.1.1.2.1"
    state_col = "2"
    current_col = "3"

    def _snmp_get(oid):
        res = ctx.run(
            ["snmpget", "-" + version, "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        return res

    def _snmp_walk(oid):
        res = ctx.run(
            ["snmpwalk", "-" + version, "-c", community, "-Oqn", host, oid],
            mutates=False,
        )
        return res

    def parse_walk(res):
        rows = {}
        if res.rc != 0 or not res.stdout:
            return rows
        for line in res.stdout.splitlines():
            idx = line.find(" ")
            if idx == -1:
                continue
            oid_part = line[:idx]
            rest = line[idx + 1:]
            # value portion may contain leading type info; -Oqn removes it
            value = rest.strip()
            rows[oid_part] = value
        return rows

    # Discovery mode
    if params.get("_discover"):
        # First verify this is a Cisco device via sysDescr
        descr_res = ctx.run(
            ["snmpget", "-" + version, "-c", community, "-Oqv", host,
             ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        is_cisco = False
        if descr_res.rc == 0 and descr_res.stdout:
            if "cisco" in descr_res.stdout.lower():
                is_cisco = True

        # Check for the entPhysicalModelName existence (not_exists detection in source)
        # The source uses not_exists(".1.3.6.1.4.1.9.9.13.1.5.1.*") to detect non-Cisco.
        # We approximate by requiring Cisco sysDescr AND successful power OID.
        if not is_cisco:
            return {"changed": False, "msg": "not a cisco device",
                    "data": {"discovery": []}}

        # Fetch names (entity physical) and power states/currents
        names_res = _snmp_walk(name_base + "." + name_oid_col)
        power_res = _snmp_walk(power_base + "." + state_col)

        # Also need currents via a separate column walk
        current_res = _snmp_walk(power_base + "." + current_col)

        names = parse_walk(names_res)
        states = parse_walk(power_res)
        currents = parse_walk(current_res)

        # Build oid_end -> name map and oid_end -> name (for readable names)
        # name OID lines look like: <base>.<col>.<oidend> <value>
        # We need the index (oid_end) which is the suffix after the column base.
        name_entries = []  # list of (oid_end, name_value)
        for oid_full, val in names.items():
            suffix = oid_full[len(name_base) + 1:]
            # suffix is like "7.<index>" or "<col>.<index>"; split on first "."
            parts = suffix.split(".", 1)
            if len(parts) == 2:
                col = parts[0]
                idx = parts[1]
                name_entries.append((idx, val))

        # Build name_map: name -> oid_end, handling duplicates (numbered)
        # Group by name value, assign numbers for duplicates
        by_name = {}
        for idx, val in name_entries:
            by_name.setdefault(val, []).append(idx)

        # We need oid_end -> name for items that have a real PSU (current >= 0, state != 0)
        # raw_states / raw_currents keyed by oid_end
        state_map = {}
        current_map = {}
        for oid_full, val in states.items():
            suffix = oid_full[len(power_base) + 1:]
            parts = suffix.split(".", 1)
            if len(parts) == 2:
                idx = parts[1]
                state_map[idx] = val
        for oid_full, val in currents.items():
            suffix = oid_full[len(power_base) + 1:]
            parts = suffix.split(".", 1)
            if len(parts) == 2:
                idx = parts[1]
                current_map[idx] = val

        # Build name -> oid_end with duplicates numbered
        name_to_oidend = {}
        for nm, idxs in by_name.items():
            if len(idxs) == 1:
                name_to_oidend[nm] = idxs[0]
            else:
                for num, idx in enumerate(idxs, start=1):
                    name_to_oidend[nm + "-" + str(num)] = idx

        # Determine real PSUs
        discovery = []
        for nm, oid_end_val in name_to_oidend.items():
            s_raw = state_map.get(oid_end_val, "0")
            c_raw = current_map.get(oid_end_val, "")
            s_val = -1
            c_val = -1
            if s_raw.lstrip("-").isdigit():
                s_val = int(s_raw)
            if c_raw.lstrip("-").isdigit():
                c_val = int(c_raw)
            # _is_real_psu: state != 0 and current >= 0
            if s_val != 0 and c_val >= 0:
                # discover only if state not in (1, 3) -- off env other, off admin
                if s_val not in (1, 3):
                    discovery.append({
                        "item": nm,
                        "params": {"warn": 0, "crit": 0},
                        "metrics": [],
                    })

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # We need to re-fetch data to find the oid_end for this item
    names_res = _snmp_walk(name_base + "." + name_oid_col)
    power_res = _snmp_walk(power_base + "." + state_col)
    current_res = _snmp_walk(power_base + "." + current_col)

    if names_res.rc != 0 or power_res.rc != 0:
        return {"changed": False,
                "msg": "failed to fetch SNMP data: " + (names_res.stderr or power_res.stderr),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    names = parse_walk(names_res)
    states = parse_walk(power_res)
    currents = parse_walk(current_res)

    # Build name -> oid_end map
    name_entries = []
    for oid_full, val in names.items():
        suffix = oid_full[len(name_base) + 1:]
        parts = suffix.split(".", 1)
        if len(parts) == 2:
            name_entries.append((parts[1], val))

    by_name = {}
    for idx, val in name_entries:
        by_name.setdefault(val, []).append(idx)

    name_to_oidend = {}
    for nm, idxs in by_name.items():
        if len(idxs) == 1:
            name_to_oidend[nm] = idxs[0]
        else:
            for num, idx in enumerate(idxs, start=1):
                name_to_oidend[nm + "-" + str(num)] = idx

    if item not in name_to_oidend:
        return {"changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oid_end_val = name_to_oidend[item]

    # Build state/current maps
    state_map = {}
    current_map = {}
    for oid_full, val in states.items():
        suffix = oid_full[len(power_base) + 1:]
        parts = suffix.split(".", 1)
        if len(parts) == 2:
            state_map[parts[1]] = val
    for oid_full, val in currents.items():
        suffix = oid_full[len(power_base) + 1:]
        parts = suffix.split(".", 1)
        if len(parts) == 2:
            current_map[parts[1]] = val

    s_raw = state_map.get(oid_end_val, "0")
    c_raw = current_map.get(oid_end_val, "")

    state_val = -1
    if s_raw.lstrip("-").isdigit():
        state_val = int(s_raw)

    # _STATE_MAP
    state_map_values = {
        1: ("WARN", "off env other"),
        2: ("OK", "on"),
        3: ("WARN", "off admin"),
        4: ("CRIT", "off denied"),
        5: ("CRIT", "off env power"),
        6: ("CRIT", "off env temp"),
        7: ("CRIT", "off env fan"),
        8: ("CRIT", "failed"),
        9: ("WARN", "on but fan fail"),
        10: ("WARN", "off cooling"),
        11: ("WARN", "off connector rating"),
        12: ("CRIT", "on but inline power fail"),
    }

    if state_val == -1:
        verdict = ("UNKNOWN", "unexpected (%s)" % s_raw)
    else:
        verdict = state_map_values.get(state_val,
                                       ("UNKNOWN", "unexpected (%d)" % state_val))

    return {"changed": False,
            "msg": "Status: %s" % verdict[1],
            "data": {"state": verdict[0], "metrics": {},
                     "details": "Item: %s, Current: %s" % (item, c_raw)}}