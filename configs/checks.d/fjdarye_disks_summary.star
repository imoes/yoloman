def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "no discovery for fjdarye_disks_summary", "data": {"discovery": []}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    fjdarye_oids = {
        ".1.3.6.1.4.1.211.1.21.1.60": ".2.12.2.1",
        ".1.3.6.1.4.1.211.1.21.1.100": ".2.19.2.1",
        ".1.3.6.1.4.1.211.1.21.1.101": ".2.12.2.1",
        ".1.3.6.1.4.1.211.1.21.1.150": ".2.19.2.1",
        ".1.3.6.1.4.1.211.1.21.1.150": ".2.19.2.1",
    }

    # Determine device OID via sysObjectID
    sysid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysid_res.rc != 0 or not sysid_res.stdout:
        return {"changed": False, "msg": "unable to query sysObjectID", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sysid = sysid_res.stdout.strip()
    disk_oid = None
    for device_oid, d_oid in fjdarye_oids.items():
        if device_oid == sysid:
            disk_oid = d_oid
            break

    if disk_oid == None:
        return {"changed": False, "msg": "device not a supported Fujitsu storage system", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base = sysid + disk_oid
    index_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1"], mutates=False)
    state_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".3"], mutates=False)

    if index_walk.rc != 0 or state_walk.rc != 0:
        return {"changed": False, "msg": "unable to walk disk tables", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    index_map = {}
    for line in index_walk.stdout.splitlines():
        parts = line.strip().split(" ", 1)
        if len(parts) == 2:
            oid_suffix = parts[0][len(base + ".1") + 1:]
            index_map[oid_suffix] = parts[1].strip().strip('"')

    state_map = {}
    for line in state_walk.stdout.splitlines():
        parts = line.strip().split(" ", 1)
        if len(parts) == 2:
            oid_suffix = parts[0][len(base + ".3") + 1:]
            state_map[oid_suffix] = parts[1].strip().strip('"')

    fjdarye_status = {
        "1": (0, "available"),
        "2": (2, "broken"),
        "3": (1, "notavailable"),
        "4": (1, "notsupported"),
        "5": (0, "present"),
        "6": (1, "readying"),
        "7": (1, "recovering"),
        "64": (1, "partbroken"),
        "65": (1, "spare"),
        "66": (0, "formatting"),
        "67": (0, "unformated"),
        "68": (1, "notexist"),
        "69": (1, "copying"),
    }

    summary = {}
    worst = 0
    for idx, disk_state in state_map.items():
        if disk_state == "3":
            continue
        entry = fjdarye_status.get(disk_state, (3, "unknown[" + disk_state + "]"))
        state_code = entry[0]
        state_desc = entry[1]
        if state_code > worst:
            worst = state_code
        summary[state_desc] = summary.get(state_desc, 0) + 1

    if len(summary) == 0:
        return {"changed": False, "msg": "no disks found (excluding notavailable)", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_text = ", ".join([s.title() + ": " + str(c) for s, c in sorted(summary.items())])

    if worst == 2:
        return {"changed": False, "msg": state_text, "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    elif worst == 1:
        return {"changed": False, "msg": state_text, "data": {"state": "WARN", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": state_text, "data": {"state": "OK", "metrics": {}, "details": ""}}