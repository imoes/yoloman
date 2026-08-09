def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["ls", "/var/log/unitrends/"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "no unitrends agent output found",
                    "data": {"discovery": []}}
        out = []
        seen = {}
        for line in res.stdout.splitlines():
            f = line.split("|")
            if len(f) < 5:
                continue
            if f[0] == "HEADER":
                sched = f[1]
                if sched not in seen:
                    seen[sched] = True
                    out.append({"item": sched, "params": {},
                                "metrics": []})
        return {"changed": False, "msg": "discovered %d schedules" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["ls", "/var/log/unitrends/"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "no unitrends agent output found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = [l.split("|") for l in res.stdout.splitlines() if l.strip()]
    message = None
    failures = ""
    details = []
    for f in lines:
        if len(f) < 4:
            continue
        if f[0] == "HEADER" and message != None:
            break
        if message != None:
            app_type, bid, backup_type, status = f[0], f[1], f[2], f[3]
            details.append("Application Type: %s (%s), %s: %s" % (app_type, bid, backup_type, status))
            continue
        if f[0] == "HEADER" and f[1] == item:
            _head, _sched_name, app_name, sched_desc, failures = f
            message = "%s Errors in last 24/h for Application %s (%s) " % (failures, app_name, sched_desc)

    if message != None:
        message += "\n" + "\n".join(details)
        state = "OK" if failures == "0" else "CRIT"
        return {"changed": False, "msg": message,
                "data": {"state": state, "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Schedule not found in Agent Output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}