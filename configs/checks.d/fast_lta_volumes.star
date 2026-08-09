def _df_check_filesystem_list(fslist_blocks, item, warn, crit):
    # Determine the filesystem block data
    # fslist_blocks: list of (volname, size_mb, free_mb, reserved)
    size_mb = 0.0
    free_mb = 0.0
    for block in fslist_blocks:
        # block is (volname, size_mb, free_mb, reserved)
        size_mb = block[1]
        free_mb = block[2]
        break
    if size_mb <= 0:
        used_pct = 0.0
    else:
        used_pct = ((size_mb - free_mb) / size_mb) * 100.0

    if used_pct >= crit:
        state = "CRIT"
    elif used_pct >= warn:
        state = "WARN"
    else:
        state = "OK"
    return state, used_pct

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Check if the SNMP agent is reachable / product is present
        # Use the sysoid probe first (Fastlane/LTA detection)
        sysoid_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysoid_res.rc != 0:
            return {"changed": False, "msg": "not present", "data": {"discovery": []}}

        # Probe for the Fastlane/LTA OID
        detect_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.27417.5.1.1.2.0"],
            mutates=False,
        )
        if detect_res.rc != 0:
            return {"changed": False, "msg": "not present", "data": {"discovery": []}}

        # Walk the volume table: base .1.3.6.1.4.1.27417.5.1.1, OIDs 2 (name), 9 (quota), 11 (used)
        name_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.27417.5.1.1.2"],
            mutates=False,
        )
        quota_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.27417.5.1.1.9"],
            mutates=False,
        )
        used_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.27417.5.1.1.11"],
            mutates=False,
        )

        volname_map = {}
        for line in name_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts[0], parts[1]
            idx = oid[len(".1.3.6.1.4.1.27417.5.1.1.2") + 1:]
            name_str = val.strip().strip('"').strip()
            volname_map[idx] = name_str

        quota_map = {}
        for line in quota_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts[0], parts[1]
            idx = oid[len(".1.3.6.1.4.1.27417.5.1.1.9") + 1:]
            quota_map[idx] = val

        used_map = {}
        for line in used_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts[0], parts[1]
            idx = oid[len(".1.3.6.1.4.1.27417.5.1.1.11") + 1:]
            used_map[idx] = val

        discovery = []
        seen = set()
        for idx in volname_map:
            if idx in quota_map and idx in used_map:
                volname = volname_map[idx]
                if volname in seen:
                    continue
                seen.add(volname)
                discovery.append({
                    "item": volname,
                    "params": {"levels": params.get("levels", (80, 90))},
                    "metrics": ["used_percent", "size", "free"],
                })

        return {
            "changed": False,
            "msg": "discovered %d volumes" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Re-walk the three columns to gather data for this specific item
    name_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.27417.5.1.1.2"],
        mutates=False,
    )
    quota_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.27417.5.1.1.9"],
        mutates=False,
    )
    used_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.27417.5.1.1.11"],
        mutates=False,
    )

    name_map = {}
    for line in name_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, val = parts[0], parts[1]
        idx = oid[len(".1.3.6.1.4.1.27417.5.1.1.2") + 1:]
        name_map[idx] = val.strip().strip('"').strip()

    quota_map = {}
    for line in quota_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, val = parts[0], parts[1]
        idx = oid[len(".1.3.6.1.4.1.27417.5.1.1.9") + 1:]
        quota_map[idx] = val

    used_map = {}
    for line in used_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, val = parts[0], parts[1]
        idx = oid[len(".1.3.6.1.4.1.27417.5.1.1.11") + 1:]
        used_map[idx] = val

    # Find the index for this item
    target_idx = None
    for idx, volname in name_map.items():
        if volname == item:
            target_idx = idx
            break

    if target_idx == None:
        return {
            "changed": False,
            "msg": "no such volume: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    quota_str = quota_map.get(target_idx, "")
    used_str = used_map.get(target_idx, "")
    if quota_str == "" or used_str == "":
        return {
            "changed": False,
            "msg": "incomplete data for volume: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Convert to bytes; parse values (strip type tags if present)
    def _clean_num(s):
        s = s.strip()
        if s.startswith('"') and s.endswith('"'):
            s = s[1:-1]
        return int(s) if s.isdigit() else 0

    quota_bytes = _clean_num(quota_str)
    used_bytes = _clean_num(used_str)
    size_mb = quota_bytes / 1048576.0
    free_mb = (quota_bytes - used_bytes) / 1048576.0

    levels = params.get("levels", (80, 90))
    warn = levels[0] if type(levels) == "list" or type(levels) == "tuple" else 80
    if type(levels) == "dict":
        warn = levels.get("warn", 80)
        crit = levels.get("crit", 90)
    else:
        warn = levels[0]
        crit = levels[1]

    if size_mb <= 0:
        used_pct = 0.0
    else:
        used_pct = ((size_mb - free_mb) / size_mb) * 100.0

    if used_pct >= crit:
        state = "CRIT"
    elif used_pct >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "%s %f%% used (%f MB of %f MB)" % (item, used_pct, size_mb - free_mb, size_mb),
        "data": {
            "state": state,
            "metrics": {"used_percent": used_pct, "size": size_mb, "free": free_mb},
            "details": "",
        },
    }