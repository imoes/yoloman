def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["multipath", "-p"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "multipath not installed",
                    "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "multipath query failed: " + res.stderr.strip(),
                    "data": {"discovery": []}}
        out = []
        seen = {}
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 6:
                continue
            disk = f[0]
            controller = f[1]
            status = f[4]
            if not disk.startswith("hdisk"):
                continue
            seen[disk] = seen.get(disk, 0) + 1
        for disk, count in sorted(seen.items()):
            out.append({"item": disk,
                        "params": {"paths": count},
                        "metrics": []})
        return {"changed": False,
                "msg": "discovered %d multipath disks" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["multipath", "-l", "-p"], mutates=False)
    if res.rc == 127:
        return {"changed": False,
                "msg": "multipath not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False,
                "msg": "multipath query failed: " + res.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    path_count = 0
    state_count = 0
    found = False
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 6:
            continue
        disk = f[0]
        status = f[4]
        if disk != item:
            continue
        found = True
        path_count += 1
        if status != "Enabled":
            state_count += 1

    if not found:
        return {"changed": False,
                "msg": "no such multipath disk: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    messages = []
    state = "OK"
    if state_count != 0 and path_count > 0:
        pct = 100.0 / path_count * state_count
        if pct >= 50:
            state = "CRIT"
        else:
            state = "WARN"
        messages.append("Paths not enabled: %d" % state_count)

    path_message = "Paths in total: %d" % path_count
    if path_count != params.get("paths", path_count):
        if state == "OK":
            state = "WARN"
        path_message = path_message + " (should be: %d)" % params.get("paths", path_count)
    messages.append(path_message)

    return {"changed": False,
            "msg": ", ".join(messages),
            "data": {"state": state, "metrics": {}, "details": ""}}