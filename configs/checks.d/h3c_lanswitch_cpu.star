def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    warn, crit = params.get("levels", (50, 75))

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.43.45.1.6.1.1.1.3"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}

        out = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_end = parts[0].strip().rsplit(".", 1)[-1]
            value_str = parts[1].strip()
            if not value_str.startswith("Gauge32:"):
                continue
            cpu_val_str = value_str.split(":", 1)[1].strip()
            if not cpu_val_str.isdigit():
                continue
            cpuid = int(cpu_val_str)

            # Apply same item generation logic as in source
            if cpuid < 256:
                switchid = 1
                cputype = "Slot"
                cpunum = cpuid
            elif cpuid >= 65536:
                switchid = cpuid // 65536
                cputype = "CPU"
                cpunum = cpuid % 65536
            else:
                switchid = 1
                cputype = "Unknown"
                cpunum = cpuid

            item_name = "Switch %d %s %d" % (switchid, cputype, cpunum)
            out.append({
                "item": item_name,
                "params": {"levels": [warn, crit]},
                "metrics": ["usage"]
            })

        return {"changed": False, "msg": "discovered %d CPU items" % len(out),
                "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.43.45.1.6.1.1.1.3"
    ], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build mapping from item names to values
    item_map = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_end = parts[0].strip().rsplit(".", 1)[-1]
        value_str = parts[1].strip()
        if not value_str.startswith("Gauge32:"):
            continue
        cpu_val_str = value_str.split(":", 1)[1].strip()
        if not cpu_val_str.isdigit():
            continue
        cpuid = int(cpu_val_str)

        # Same item generation logic
        if cpuid < 256:
            switchid = 1
            cputype = "Slot"
            cpunum = cpuid
        elif cpuid >= 65536:
            switchid = cpuid // 65536
            cputype = "CPU"
            cpunum = cpuid % 65536
        else:
            switchid = 1
            cputype = "Unknown"
            cpunum = cpuid

        item_name = "Switch %d %s %d" % (switchid, cputype, cpunum)
        item_map[item_name] = cpuid

    # Look up the requested item
    if item not in item_map:
        return {"changed": False, "msg": "%s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    util = item_map[item]
    infotext = "average usage was %d%% over last 5 minutes." % util

    if util > crit:
        state = "CRIT"
    elif util > warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": {"usage": util}, "details": ""}}