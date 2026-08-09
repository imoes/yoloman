def _snmp_get(ctx, community, host, oid):
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, oid
    ], mutates=False)
    if res.rc == 0:
        return res.stdout.strip()
    return None

def _snmp_walk(ctx, community, host, oid):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid
    ], mutates=False)
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            lines.append((parts[0], parts[1]))
    return lines

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.2021.2.1"

    if params.get("_discover"):
        names = _snmp_walk(ctx, community, host, base + ".2")
        items = []
        for oid, value in names:
            name = value.strip().strip('"')
            item = name.replace("-Processes", "")
            items.append({
                "item": item,
                "params": {},
                "metrics": ["processes"]
            })
        return {
            "changed": False,
            "msg": "discovered %d process entries" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    names = _snmp_walk(ctx, community, host, base + ".2")
    target_oid = None
    for oid, value in names:
        name = value.strip().strip('"')
        if name.replace("-Processes", "") == item:
            target_oid = oid
            break

    if target_oid == None:
        return {
            "changed": False,
            "msg": "no such process entry: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    index = target_oid[len(base + ".2") + 1:] if target_oid.startswith(base + ".2.") else target_oid.split(".")[-1]

    count = _snmp_get(ctx, community, host, base + ".5." + index)
    err_flag = _snmp_get(ctx, community, host, base + ".100." + index)
    err_msg = _snmp_get(ctx, community, host, base + ".101." + index)
    pr_min = _snmp_get(ctx, community, host, base + ".3." + index)
    pr_max = _snmp_get(ctx, community, host, base + ".4." + index)

    if count == None or err_flag == None:
        return {
            "changed": False,
            "msg": "failed to retrieve process data for " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    count_val = int(count) if count.lstrip("-").isdigit() else 0
    err_flag_val = int(err_flag) if err_flag.lstrip("-").isdigit() else 0

    if err_flag_val == 0:
        state = "OK"
        infotext = "Total: %d" % count_val
    else:
        state = "CRIT"
        infotext = "Total: %s" % count
        if err_msg and err_msg.strip() and err_msg.strip() != '""' and err_msg.strip() != '""':
            clean_msg = err_msg.strip().strip('"')
            if clean_msg:
                infotext += ", " + clean_msg
        infotext += " (lower/upper crit at %s/%s)" % (
            pr_min.strip().strip('"') if pr_min else "?",
            pr_max.strip().strip('"') if pr_max else "?"
        )

    return {
            "changed": False,
            "msg": infotext,
            "data": {
                "state": state,
                "metrics": {"processes": count_val},
                "details": ""
            }
    }