def _decode_status(status_str):
    status_str = status_str.strip()
    if status_str == "1":
        return ("running", "running", "")
    if status_str == "2":
        return ("runnable", "runnable", "waiting for resource")
    if status_str == "3":
        return ("not_runnable", "not runnable", "loaded but waiting for event")
    if status_str == "4":
        return ("invalid", "invalid", "not loaded")
    return (status_str, "unknown[" + status_str + "]", "")

def _snmp_get_multi(ctx, community, host, oids):
    results = {}
    for oid in oids:
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc == 0 and res.stdout != "":
            results[oid] = res.stdout.strip()
        else:
            results[oid] = None
    return results

def _snmp_walk_table(ctx, community, host, column_oids):
    """Walk multiple columns of the hrSWRun table, correlating by index."""
    table = {}
    for col_name, base_oid in column_oids.items():
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
            mutates=False,
        )
        if res.rc != 0 or res.stdout == "":
            continue
        for line in res.stdout.splitlines():
            space_idx = line.find(" ")
            if space_idx == -1:
                continue
            oid = line[:space_idx]
            val_part = line[space_idx + 1:]
            val = val_part.strip().strip('"')
            idx = oid[len(base_oid) + 1:]
            if idx not in table:
                table[idx] = {}
            table[idx][col_name] = val
    return table

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Probe for SNMP support (rc==127 means not installed)
    probe = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.3.0"], mutates=False)
    if probe.rc == 127:
        if params.get("_discover"):
            return {"changed": False, "msg": "snmpget not found", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "snmp not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": "", "host_labels": {}}}

    # Test that HOST-RESOURCES-MIB is accessible
    if probe.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "SNMP unreachable", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "SNMP unreachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": "", "host_labels": {}}}

    # Column OIDs from the SNMPTree definition
    col_oids = {
        "name": ".1.3.6.1.2.1.25.4.2.1.2",
        "path": ".1.3.6.1.2.1.25.4.2.1.4",
        "status": ".1.3.6.1.2.1.25.4.2.1.7",
    }

    # Discovery mode: enumerate all running processes
    if params.get("_discover"):
        table = _snmp_walk_table(ctx, community, host, col_oids)
        processes = []
        for idx in sorted(table.keys()):
            row = table[idx]
            name = row.get("name", "")
            if name == "":
                continue
            path = row.get("path", "")
            status = row.get("status", "0")
            state_key, state_short, state_long = _decode_status(status)
            processes.append({
                "name": name.strip(":"),
                "path": path,
                "state_key": state_key,
                "state_short": state_short,
                "state_long": state_long,
            })

        discovery = []
        seen = {}
        for proc in processes:
            service_descr = "Process " + proc["name"]
            if service_descr in seen:
                continue
            seen[service_descr] = True
            discovery.append({
                "item": service_descr,
                "params": {
                    "match_name_or_path": ("match_name", proc["name"]),
                    "match_status": None,
                    "match_groups": [],
                    "levels": (1, 1, 99999, 99999),
                },
                "metrics": ["processes"],
            })

        return {
            "changed": False,
            "msg": "discovered %d process services" % len(discovery),
            "data": {
                "discovery": discovery,
                "host_labels": {"cmk/snmp_mib": "host-resources-mib"},
            },
        }

    # Check mode: evaluate one item
    item = params.get("item", "")
    if item.startswith("Process "):
        target_name = item[len("Process "):]
    else:
        target_name = item

    match_name_or_path = params.get("match_name_or_path")
    match_status = params.get("match_status")
    match_groups = params.get("match_groups")

    table = _snmp_walk_table(ctx, community, host, col_oids)
    processes = []
    for idx in sorted(table.keys()):
        row = table[idx]
        name = row.get("name", "")
        if name == "":
            continue
        path = row.get("path", "")
        status = row.get("status", "0")
        state_key, state_short, state_long = _decode_status(status)
        processes.append({
            "name": name.strip(":"),
            "path": path,
            "state_key": state_key,
            "state_short": state_short,
            "state_long": state_long,
        })

    # Match processes against the rule
    count = 0
    states = {}
    for proc in processes:
        matched = True
        if match_status and proc["state_key"] not in match_status:
            matched = False
        if matched and match_name_or_path:
            match_type, match_pattern = match_name_or_path
            pattern_val = proc["name"] if match_type == "match_name" else proc["path"]
            if match_pattern != "match_all" and pattern_val != match_pattern:
                matched = False
        if matched:
            count += 1
            key = proc["state_key"]
            if key not in states:
                states[key] = {"short": proc["state_short"], "long": proc["state_long"], "count": 0}
            states[key]["count"] += 1

    # Apply levels: (lc, lw, uw, uc) -> levels_lower=(lw, lc), levels_upper=(uw, uc)
    levels = params.get("levels", (1, 1, 99999, 99999))
    lc, lw, uw, uc = levels
    state = "OK"
    if count >= uw:
        state = "CRIT"
    elif count >= lw:
        state = "WARN"
    elif count <= lc:
        state = "CRIT"
    elif count <= lw:
        state = "WARN"

    # Status-based state override from params
    status_map = dict(params.get("status", []))
    for skey in states:
        s = status_map.get(skey, 0)
        if s == 3 and state == "OK":  # CRIT
            state = "CRIT"
        elif s == 2 and state == "OK":  # WARN
            state = "WARN"
        elif s == 1:  # OK
            pass
        elif s == 4 and state == "OK":  # CRIT
            state = "CRIT"

    # Build message
    parts = []
    for skey, info in sorted(states.items()):
        s_info = info["short"]
        if info["long"]:
            s_info = s_info + " (" + info["long"] + ")"
        parts.append(str(info["count"]) + " " + s_info)

    if not parts:
        if count == 0:
            state = "UNKNOWN"
            msg = "no matching process found: " + target_name
        else:
            msg = "Process %s: %s" % (target_name, count)
    else:
        msg = " ".join(parts)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"processes": count},
            "details": "\n".join(parts),
            "host_labels": {},
        },
    }