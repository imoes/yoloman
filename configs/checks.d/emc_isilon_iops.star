def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sys_oid = ".1.3.6.1.2.1.1.1.0"
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, sys_oid],
            mutates=False,
        )
        if sys_res.rc == 127:
            return {"changed": False, "msg": "snmpget not installed",
                    "data": {"discovery": []}}
        if sys_res.rc != 0 or sys_res.stdout.find("isilon") == -1:
            return {"changed": False, "msg": "not an Isilon system",
                    "data": {"discovery": []}}

        base = ".1.3.6.1.4.1.12124.2.2.52.1"
        name_col = base + ".2"
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, name_col],
            mutates=False,
        )
        if walk.rc == 127:
            return {"changed": False, "msg": "snmpwalk not installed",
                    "data": {"discovery": []}}
        if walk.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}

        discovery = []
        seen = []
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            idx = line[:sp]
            idx_suffix = idx[len(name_col) + 1:]
            val_part = line[sp + 1:].strip()
            if val_part.startswith('"') and val_part.endswith('"'):
                val_part = val_part[1:-1]
            if idx_suffix and val_part:
                if val_part not in seen:
                    seen.append(val_part)
                    discovery.append({"item": val_part, "params": {},
                                      "metrics": ["iops"]})
        return {"changed": False,
                "msg": "discovered %d disk IO items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn = params.get("warn", 0)
    crit = params.get("crit", 0)

    iops_col = ".1.3.6.1.4.1.12124.2.2.52.1.3"
    base = ".1.3.6.1.4.1.12124.2.2.52.1"
    name_col = base + ".2"

    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, name_col],
        mutates=False,
    )
    if walk.rc == 127:
        return {"changed": False, "msg": "snmpwalk not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if walk.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    index = None
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val_part = line[sp + 1:].strip()
        if val_part.startswith('"') and val_part.endswith('"'):
            val_part = val_part[1:-1]
        if val_part == item:
            index = oid[len(name_col) + 1:]
            break

    if index == None:
        return {"changed": False,
                "msg": "disk not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    iops_oid = iops_col + "." + index
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, iops_oid],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "could not read iops for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    if raw.startswith('"') and raw.endswith('"'):
        raw = raw[1:-1]
    iops = int(raw) if raw.isdigit() else 0

    if crit > 0 and iops >= crit:
        state = "CRIT"
    elif warn > 0 and iops >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "Disk %s IO: %d/s" % (item, iops),
            "data": {"state": state, "metrics": {"iops": iops},
                     "details": "Disk operations: %d/s" % iops}}