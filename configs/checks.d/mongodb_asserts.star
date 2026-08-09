def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mongosh", "--eval", "JSON.stringify(db.serverStatus().asserts)", "--quiet", "--host", "localhost", "--port", "27017"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "mongosh not available", "data": {"discovery": [], "host_labels": {}}}
        out = res.stdout.strip()
        if not out:
            return {"changed": False, "msg": "no asserts data", "data": {"discovery": [], "host_labels": {}}}
        d = json.decode(out)
        if d == None:
            return {"changed": False, "msg": "no asserts data", "data": {"discovery": [], "host_labels": {}}}
        if len(d) == 0:
            return {"changed": False, "msg": "no asserts", "data": {"discovery": [], "host_labels": {}}}
        metrics = []
        for k in sorted(d.keys()):
            if type(d.get(k)) == "float" or type(d.get(k)) == "int":
                metrics.append("assert_" + k)
        return {"changed": False, "msg": "discovered 1 service", "data": {"discovery": [{"item": "", "params": {}, "metrics": metrics}], "host_labels": {}}}
    item = params.get("item", "")
    res = ctx.run(["mongosh", "--eval", "JSON.stringify(db.serverStatus().asserts)", "--quiet", "--host", "localhost", "--port", "27017"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "mongosh not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": "mongodb not reachable"}}
    out = res.stdout.strip()
    if not out:
        return {"changed": False, "msg": "no asserts data", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no asserts data returned"}}
    d = json.decode(out)
    if d == None or len(d) == 0:
        return {"changed": False, "msg": "no asserts data", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no asserts data returned"}}
    now = ctx.run(["date", "+%s"], mutates=False)
    t = 0.0
    if now.rc == 0 and now.stdout.strip() != "":
        t = float(now.stdout.strip())
    warn_def = {"regular": 5.0, "warning": 1.0, "user": 1.0, "info": 10.0, "getmore": 1.0}
    crit_def = {"regular": 10.0, "warning": 5.0, "user": 5.0, "info": 20.0, "getmore": 5.0}
    first = True
    lines = []
    all_metrics = {}
    worst = "OK"
    for k in sorted(d.keys()):
        v = d.get(k)
        if not (type(v) == "float" or type(v) == "int"):
            continue
        mname = "assert_" + k
        all_metrics[mname] = int(v)
        if first:
            first = False
        w = params.get(mname + "_levels")
        if w != None and type(w) == "list" and len(w) >= 1:
            warn = w[0]
        else:
            warn = warn_def.get(k, 1.0)
        if w != None and type(w) == "list" and len(w) >= 2:
            crit = w[1]
        else:
            crit = crit_def.get(k, 5.0)
        if v >= crit:
            st = "CRIT"
        elif v >= warn:
            st = "WARN"
        else:
            st = "OK"
        if st == "CRIT" or worst == "OK":
            worst = st
        lines.append("%s: %d" % (k.title(), int(v)))
    msg = ", ".join(lines) if lines else "no asserts"
    return {"changed": False, "msg": msg, "data": {"state": worst, "metrics": all_metrics, "details": msg}}