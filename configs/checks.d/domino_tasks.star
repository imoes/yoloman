def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.334.72.1.1.6.1.2.1.4"
    item_oid = params.get("item_oid", "")
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no domino tasks found", "data": {"discovery": []}}
        items = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            value = parts[1].strip().strip('"')
            if not oid_full.startswith(base_oid + "."):
                continue
            index = oid_full[len(base_oid) + 1:]
            if not index:
                continue
            items.append({"item": value, "params": {"levels": [1, 1, 99999, 99999], "item_oid": index}, "metrics": ["count"]})
        return {"changed": False, "msg": "discovered %d domino tasks" % len(items), "data": {"discovery": items}}
    item = params.get("item", "")
    item_oid = params.get("item_oid", "")
    if not item_oid:
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no domino task named '%s' found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        found_oid = ""
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            value = parts[1].strip().strip('"')
            if value == item and oid_full.startswith(base_oid + "."):
                found_oid = oid_full[len(base_oid) + 1:]
                break
        if not found_oid:
            return {"changed": False, "msg": "no domino task named '%s' found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        item_oid = found_oid
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + "." + item_oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no domino task '%s' found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("levels", [1, 1, 99999, 99999])
    warn_count = levels[0] if len(levels) >= 1 else 1
    crit_count = levels[1] if len(levels) >= 2 else 1
    count = 1
    state = "CRIT" if count >= crit_count else ("WARN" if count >= warn_count else "OK")
    return {"changed": False, "msg": "Task %s: state %s (count=%d)" % (item, state, count), "data": {"state": state, "metrics": {"count": count}, "details": "Domino task %s is active" % item}}