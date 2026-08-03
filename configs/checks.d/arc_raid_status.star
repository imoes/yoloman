def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["arecactl", "status", "array"], mutates=False)
        if res.rc == 127 or not res.stdout:
            return {"changed": False, "msg": "no areca raid controller found",
                    "data": {"discovery": [], "host_labels": {}}}
        out = []
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 6:
                continue
            item = f[0]
            n_disks = int(f[-5])
            out.append({"item": item, "params": {"n_disks": n_disks},
                        "metrics": [], "service_labels": {}})
        return {"changed": False,
                "msg": "discovered %d raid arrays" % len(out),
                "data": {"discovery": out, "host_labels": {}}}

    item = params.get("item", "")
    res = ctx.run(["arecactl", "status", "array"], mutates=False)
    if res.rc == 127 or not res.stdout:
        return {"changed": False, "msg": "no areca raid controller found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 6 or f[0] != item:
            continue
        raid_state = f[-1]
        if raid_state in ("Checking", "Normal"):
            state = "OK"
        elif raid_state == "Rebuilding":
            state = "WARN"
        elif raid_state in ("Degrade", "Incompleted"):
            state = "CRIT"
        else:
            state = "CRIT"
        i_disks = params.get("n_disks", int(f[-5]))
        c_disks = int(f[-5])
        if i_disks != c_disks:
            return {"changed": False,
                    "msg": "Number of disks has changed from %d to %d" % (i_disks, c_disks),
                    "data": {"state": "CRIT", "metrics": {},
                             "details": raid_state.title()}}
        return {"changed": False, "msg": raid_state.title(),
                "data": {"state": state, "metrics": {},
                         "details": "%s %s" % (item, raid_state)}}
    return {"changed": False, "msg": "no such raid array: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}