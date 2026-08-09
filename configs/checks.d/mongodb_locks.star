def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mongostat", "--host", params.get("host", "localhost"), "--quiet", "1", "1"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no MongoDB instance found", "data": {"discovery": []}}
        out = []
        out.append({"item": "", "params": {}, "metrics": [
            "clients_readers_locks", "clients_total_locks", "clients_writers_locks",
            "queue_readers_locks", "queue_total_locks", "queue_writers_locks",
        ]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    # Probe for the real thing first
    probe = ctx.run(["mongo", "--host", params.get("host", "localhost"), "--quiet", "--eval", "db.serverStatus().ok"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "mongo binary not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if probe.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no MongoDB instance found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run([
        "mongo",
        "--host", params.get("host", "localhost"),
        "--quiet", "--eval",
        "var d=db.serverStatus().locks; var a=db.serverStatus().globalLock; print('activeClients readers', a.activeClients.readers); print('activeClients total', a.activeClients.total); print('activeClients writers', a.activeClients.writers); print('currentQueue readers', d.readers); print('currentQueue total', d.total); print('currentQueue writers', d.writers);",
    ], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "could not read MongoDB locks", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    metrics = {}
    for line in lines:
        f = line.split()
        if len(f) != 3:
            continue
        what = f[0]
        name = f[1]
        count = f[2]
        param_name = "clients" if what.startswith("active") else "queue"
        metric_name = param_name + "_" + name + "_locks"
        val = int(count) if count.isdigit() else 0
        metrics[metric_name] = val

    if not metrics:
        return {"changed": False, "msg": "no lock data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    details = " | ".join(["%s: %d" % (k, v) for k, v in metrics.items()])
    return {"changed": False, "msg": details, "data": {"state": "OK", "metrics": metrics, "details": details}}