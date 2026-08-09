def main(ctx, params):
    if params.get("_discover"):
        out = []
        res = ctx.run(["psql", "-t", "-c",
                       "SELECT target, result, complete, instance FROM unitrends_replication_last24 ORDER BY target"],
                       mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no unitrends database source found",
                    "data": {"discovery": []}}
        targets = []
        for line in res.stdout.splitlines():
            parts = line.split("|")
            if len(parts) < 4:
                continue
            target = parts[0].strip()
            if len(parts) >= 5:
                complete = parts[2].strip()
                instance = parts[4].strip()
            if target == "":
                continue
            if target not in targets:
                targets.append(target)
        for t in targets:
            out.append({"item": t, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["psql", "-t", "-c",
                   "SELECT result, complete, instance FROM unitrends_replication_last24 WHERE target = '" + item + "' ORDER BY target"],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no unitrends database source found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    not_successfull = []
    found = False
    for line in res.stdout.splitlines():
        parts = line.split("|")
        if len(parts) < 3:
            continue
        found = True
        result = parts[0].strip()
        if result != "Success":
            instance = parts[2].strip()
            not_successfull.append((result, instance))
    if not found:
        return {"changed": False, "msg": "No Entries found for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if len(not_successfull) == 0:
        return {"changed": False, "msg": "All Replications in the last 24 hours Successfull",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    messages = []
    for result, instance in not_successfull:
        messages.append("Target: " + item + ", Result: " + result + ", Instance: " + instance + "  ")
    summary = "Errors from the last 24 hours: " + "/ ".join(messages)
    return {"changed": False, "msg": summary,
            "data": {"state": "CRIT", "metrics": {}, "details": ""}}