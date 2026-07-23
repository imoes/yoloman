def main(ctx, params):
    # Map Cisco fan operational states to Checkmk states and descriptions
    map_states = {
        "1": ("UNKNOWN", "unknown"),
        "2": ("OK", "powered on"),
        "3": ("CRIT", "powered down"),
        "4": ("CRIT", "partial failure, needs replacement as soon as possible."),
    }

    if params.get("_discover"):
        # Discover fan trays: walk both SNMP trees
        # Tree 1: .1.3.6.1.4.1.9.9.117.1.4.1.1.{end_oid}.1 -> operState (string)
        # Tree 2: .1.3.6.1.2.1.47.1.1.1.1.{end_oid}.7 -> entPhysicalName (string, cached)
        res1 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.9.9.117.1.4.1.1.1"
        ], mutates=False)

        res2 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.2.1.47.1.1.1.1.7"
        ], mutates=False)

        # Parse SNMP output lines: "OID = STRING: value"
        statuses = {}  # end_oid -> (state_str, desc_str)
        for line in res1.stdout.splitlines():
            parts = line.strip().split(" = STRING: ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            # Extract end_oid: last part after last dot
            end_oid = oid.rsplit(".", 1)[-1]
            state_str = parts[1].strip().strip('"')
            statuses[end_oid] = map_states.get(state_str, ("UNKNOWN", "unexpected(%s)" % state_str))

        entries_by_name = {}
        for line in res2.stdout.splitlines():
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            end_oid = oid.rsplit(".", 1)[-1]
            if end_oid not in statuses:
                continue

            value = parts[1].strip()
            if value.startswith("STRING: "):
                raw_name = value[8:].strip().strip('"')
            else:
                raw_name = value.strip().strip('"')

            name = (raw_name or "").strip()
            if not name:
                name = end_oid

            entries_by_name.setdefault(name, [])
            entries_by_name[name].append(statuses[end_oid])

        # Build items: disambiguate duplicates
        items = []
        for name, infos in entries_by_name.items():
            if len(infos) > 1:
                for k, _ in enumerate(infos):
                    items.append({
                        "item": "%s-%d" % (name, k + 1),
                        "params": {},
                        "metrics": []
                    })
            else:
                items.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })

        return {"changed": False, "msg": "discovered %d fan trays" % len(items),
                "data": {"discovery": items}}

    # Check mode: verify one item
    item = params.get("item", "")
    # Re-run discovery to get the state for this item (read-only, no side-effects)
    res1 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.9.9.117.1.4.1.1.1"
    ], mutates=False)

    res2 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.2.1.47.1.1.1.1.7"
    ], mutates=False)

    # Parse both trees identically to discover mode
    statuses = {}
    for line in res1.stdout.splitlines():
        parts = line.strip().split(" = STRING: ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        end_oid = oid.rsplit(".", 1)[-1]
        state_str = parts[1].strip().strip('"')
        statuses[end_oid] = map_states.get(state_str, ("UNKNOWN", "unexpected(%s)" % state_str))

    entries_by_name = {}
    for line in res2.stdout.splitlines():
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        end_oid = oid.rsplit(".", 1)[-1]
        if end_oid not in statuses:
            continue

        value = parts[1].strip()
        if value.startswith("STRING: "):
            raw_name = value[8:].strip().strip('"')
        else:
            raw_name = value.strip().strip('"')

        name = (raw_name or "").strip()
        if not name:
            name = end_oid

        entries_by_name.setdefault(name, [])
        entries_by_name[name].append(statuses[end_oid])

    parsed = {}
    for name, infos in entries_by_name.items():
        if len(infos) > 1:
            for k, state_info in enumerate(infos):
                parsed["%s-%d" % (name, k + 1)] = state_info
        else:
            parsed[name] = infos[0]

    # Look up requested item
    if item not in parsed:
        return {"changed": False, "msg": "fan tray not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state, desc = parsed[item]
    return {"changed": False, "msg": "Status: " + desc,
            "data": {"state": state, "metrics": {}, "details": ""}}
