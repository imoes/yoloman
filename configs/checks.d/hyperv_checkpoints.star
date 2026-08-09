def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
            "Get-VM | ForEach-Object { $vm = $_; Get-VMSnapshot -VM $vm | ForEach-Object { Write-Output ($_.VMName + ' ' + $_.Name + ' ' + [int]((Get-Date) - $_.CreationTime).TotalSeconds) } }"],
            mutates=False)
        found = res.rc == 0 and res.stdout.strip() != ""
        if not found:
            return {"changed": False, "msg": "no Hyper-V VMs with checkpoints found",
                    "data": {"discovery": [], "host_labels": {"cmk/hyperv": "yes"}}}
        return {"changed": False, "msg": "discovered HyperV Checkpoints",
                "data": {"discovery": [
                    {"item": "", "params": {"age_oldest": (86400,), "age": (86400,)},
                     "metrics": ["age_oldest", "age"],
                     "service_labels": {"cmk/hyperv": "yes"}}
                ], "host_labels": {"cmk/hyperv": "yes"}}}
    item = params.get("item", "")
    res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
        "Get-VM | ForEach-Object { $vm = $_; Get-VMSnapshot -VM $vm | ForEach-Object { Write-Output ($_.VMName + ' ' + $_.Name + ' ' + [int]((Get-Date) - $_.CreationTime).TotalSeconds) } }"],
        mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no HyperV Checkpoints found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no VMs or snapshots present"}}
    snapshots = []
    for line in res.stdout.splitlines():
        parts = line.split(" ")
        if len(parts) < 3:
            continue
        age_part = parts[-1]
        age = int(age_part) if age_part.lstrip("-").isdigit() else 0
        snapshots.append((parts[0], age))
    count = len(snapshots)
    msg = "%d checkpoints" % count
    if count == 0:
        return {"changed": False, "msg": msg, "data": {"state": "OK", "metrics": {}, "details": ""}}
    metrics = {}
    details = ""
    for title, key, snapshot in [
        ("Oldest", "age_oldest", max(snapshots, key=lambda x: x[1])),
        ("Last", "age", snapshots[-1]),
    ]:
        name, age = snapshot[0], snapshot[1]
        if age < 0:
            return {"changed": False,
                    "msg": msg,
                    "data": {"state": "WARN", "metrics": {"age_oldest": age, "age": snapshots[-1][1]},
                             "details": "%s (%s): negative checkpoint age (%ds), check for clock skew" % (title, name, age)}}
        metrics[key] = float(age)
        warn = params.get(key)
        crit = None
        if type(warn) == "list" and len(warn) >= 2:
            crit = warn[1]
            warn = warn[0]
        elif type(warn) == "tuple" and len(warn) >= 2:
            crit = warn[1]
            warn = warn[0]
        state = "OK"
        if crit != None and age >= crit:
            state = "CRIT"
        elif warn != None and age >= warn:
            state = "WARN"
        if state == "CRIT":
            return {"changed": False, "msg": msg,
                    "data": {"state": state, "metrics": metrics,
                             "details": "%s (%s): age %ds >= %ds" % (title, name, age, crit)}}
    final_state = "OK"
    for k in metrics.keys():
        if k == "age_oldest":
            w = params.get("age_oldest")
        else:
            w = params.get("age")
        if type(w) == "list" and len(w) >= 1:
            warn = w[0]
            if metrics[k] >= warn:
                final_state = "WARN"
        elif type(w) == "tuple" and len(w) >= 1:
            warn = w[0]
            if metrics[k] >= warn:
                final_state = "WARN"
    return {"changed": False, "msg": msg, "data": {"state": final_state, "metrics": metrics, "details": details}}