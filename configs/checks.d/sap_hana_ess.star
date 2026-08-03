def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["HDB", "info"], mutates=False)
        if res.rc == 127 or not res.stdout:
            if res.rc != 0:
                return {"changed": False, "msg": "no HDB found",
                        "data": {"discovery": [], "host_labels": {"cmk/os_family": "linux"}}}
        instances = {}
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) >= 3 and f[0] == "ess":
                sid_inst = f[1]
                instances.setdefault(sid_inst, [])
                for k in range(2, len(f) - 1, 2):
                    instances[sid_inst].append([f[k], f[k + 1]])
        discovery = []
        for item in sorted(instances.keys()):
            discovery.append({"item": item, "params": {}, "metrics": ["threads"]})
        return {"changed": False,
                "msg": "discovered %d SAP HANA ESS instances" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    res = ctx.run(["HDB", "info"], mutates=False)
    if res.rc == 127 or not res.stdout:
        return {"changed": False, "msg": "no SAP HANA instance found: HDB not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = {}
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 4 or f[0] != "ess":
            continue
        sid_inst = f[1]
        inst_data = {}
        k = 2
        while k + 1 < len(f):
            key = f[k]
            val = f[k + 1]
            if key == "started" and val.isdigit():
                inst_data[key] = int(val)
            else:
                inst_data[key] = val
            k = k + 2
        section[sid_inst] = inst_data
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "SAP HANA instance %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not data:
        return {"changed": False, "msg": "login into database failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    active_state_name = str(data.get("active", "unknown"))
    if active_state_name == "unknown":
        state = "UNKNOWN"
    elif active_state_name in ["false", "no"]:
        state = "CRIT"
    else:
        state = "OK"
    started_threads = data.get("started")
    if started_threads == None or started_threads < 1:
        thread_state = "CRIT"
        started_threads = 0
    else:
        thread_state = "OK"
    overall = "OK"
    if state == "CRIT" or thread_state == "CRIT":
        overall = "CRIT"
    elif state == "WARN" or thread_state == "WARN":
        overall = "WARN"
    elif state == "UNKNOWN":
        overall = "UNKNOWN"
    msg = "Active status: %s, Started threads: %s" % (active_state_name, started_threads)
    return {"changed": False, "msg": msg,
            "data": {"state": overall, "metrics": {"threads": started_threads}, "details": ""}}