# Module-level constants for SNMP section base OID
_BASE_OID = ".1.3.6.1.4.1.334.72.1.1.6.1.2.1"

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), _BASE_OID + ".4"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovery failed",
                "data": {"discovery": []}
            }

        items = []
        for line in res.stdout.splitlines():
            # Format: OID = STRING: "task_name"
            idx = line.find('"')
            if idx == -1:
                continue
            task_name = line[idx + 1:].rstrip('"')
            if task_name:
                items.append({
                    "item": task_name,
                    "params": {"levels": (1, 1, 99999, 99999)},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d domino tasks" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), _BASE_OID + ".4"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to fetch domino tasks",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    found = False
    for line in res.stdout.splitlines():
        idx = line.find('"')
        if idx == -1:
            continue
        task_name = line[idx + 1:].rstrip('"')
        if task_name == item:
            found = True
            break

    levels = params.get("levels", (1, 1, 99999, 99999))
    # levels format: (warn_lower, warn_upper, crit_lower, crit_upper)
    # This check only verifies the task exists (count = 1), so we treat count as the metric.
    # Expected count is 1 for a running task; 0 means missing task.
    count = 1 if found else 0

    # Determine state based on levels (treat as count thresholds)
    crit_lower, crit_upper, warn_lower, warn_upper = levels[2], levels[3], levels[0], levels[1]
    state = "OK"
    if count <= crit_lower or count >= crit_upper:
        state = "CRIT"
    elif count <= warn_lower or count >= warn_upper:
        state = "WARN"

    msg = "%s: %s" % (item, "running" if found else "not running")

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"tasks": count},
            "details": ""
        }
    }
