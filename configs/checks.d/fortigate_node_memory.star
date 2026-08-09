def main(ctx, params):
    # ---- discovery mode ----
    if params.get("_discover"):
        # Detect: this is a FortiGate device in HA (cluster) mode.
        # OID_SysObjectID walk -> Fortinet enterprise prefix
        sysid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), "1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid.rc != 0 or sysid.stdout.strip() == "":
            return {"changed": False, "msg": "FortiGate not detected",
                    "data": {"discovery": []}}
        if not sysid.stdout.startswith(".1.3.6.1.4.1.12356.101.1"):
            return {"changed": False, "msg": "FortiGate not detected",
                    "data": {"discovery": []}}
        # Exclude standalone FortiGates (cluster id == 1)
        cluster_id = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), "1.3.6.1.4.1.12356.101.13.1.1.0"],
            mutates=False,
        )
        if cluster_id.rc == 0 and cluster_id.stdout.strip() == "1":
            return {"changed": False, "msg": "FortiGate standalone mode",
                    "data": {"discovery": []}}

        # Walk the memory table: base .1.3.6.1.4.1.12356.101.13.2.1.1
        # columns: 11 (member), 4 (usage), OIDEnd (index)
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             "1.3.6.1.4.1.12356.101.13.2.1.1.4"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no FortiGate node memory data",
                    "data": {"discovery": []}}

        usage_map = {}
        base_u = "1.3.6.1.4.1.12356.101.13.2.1.1.4"
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts
            idx = oid[len(base_u) + 1:]
            usage_map[idx] = val

        # Walk the member-name column to get display names
        member_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             "1.3.6.1.4.1.12356.101.13.2.1.1.11"],
            mutates=False,
        )
        name_map = {}
        base_m = "1.3.6.1.4.1.12356.101.13.2.1.1.11"
        if member_walk.rc == 0:
            mlines = member_walk.stdout.splitlines()
            for line in mlines:
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                moid, mval = parts
                midx = moid[len(base_m) + 1:]
                name_map[midx] = mval

        discovery = []
        keys = sorted(usage_map.keys())
        for idx in keys:
            name = name_map.get(idx)
            if name == "" or name == None:
                name = "Node " + idx
            discovery.append({
                "item": name,
                "params": {"levels": [70, 80]},
                "metrics": ["mem_used_percent"],
            })

        # Cluster-only (single entry) case
        if len(discovery) == 0 and len(usage_map) == 1:
            for idx in usage_map.keys():
                name = name_map.get(idx)
                if name == "" or name == None:
                    name = "Cluster"
                discovery.append({
                    "item": name,
                    "params": {"levels": [70, 80]},
                    "metrics": ["mem_used_percent"],
                })

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # ---- check mode ----
    item = params.get("item", "")
    warn = 70
    crit = 80
    levels = params.get("levels")
    if levels != None:
        warn = levels[0]
        crit = levels[1]

    # Re-walk to find this item's index by member name
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         "1.3.6.1.4.1.12356.101.13.2.1.1.11"],
        mutates=False,
    )
    if walk.rc != 0 or walk.stdout == "":
        return {"changed": False,
                "msg": "no FortiGate node memory data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    usage = None
    base_m = "1.3.6.1.4.1.12356.101.13.2.1.1.11"
    mlines = walk.stdout.splitlines()
    for line in mlines:
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, val = parts
        idx = oid[len(base_m) + 1:]
        name = val
        if name == "" or name == None:
            name = "Node " + idx
        if name == item:
            get_u = ctx.run(
                ["snmpget", "-v2c", "-c", params.get("community", "public"),
                 "-Oqv", params.get("host", "localhost"),
                 "1.3.6.1.4.1.12356.101.13.2.1.1.4." + idx],
                mutates=False,
            )
            if get_u.rc == 0:
                try_u = get_u.stdout.strip()
                if try_u != "":
                    usage = float(try_u)
            break

    if usage == None:
        return {"changed": False,
                "msg": "no memory data for item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    pct = int(usage + 0.5)
    if pct >= crit:
        state = "CRIT"
    elif pct >= warn:
        state = "WARN"

    label = "%d%%" % pct
    return {"changed": False,
            "msg": "Memory %s: Usage %s" % (item, label),
            "data": {"state": state,
                     "metrics": {"mem_used_percent": pct},
                     "details": ""}}