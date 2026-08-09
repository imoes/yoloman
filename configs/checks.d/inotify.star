def main(ctx, params):
    if params.get("_discover"):
        paths = []
        stat_res = ctx.run(["stat", "-c", "%Y %n", "/tmp"], mutates=False)
        if stat_res.rc == 0:
            paths.append("/tmp")

        discovery = []
        for path in paths:
            st = ctx.stat(path)
            if st and st.exists:
                discovery.append({
                    "item": "Folder " + path,
                    "params": {"age_last_operation": []},
                    "metrics": ["age_last_operation"],
                })

        if len(discovery) == 0:
            return {"changed": False, "msg": "no inotify watches found",
                    "data": {"discovery": []}}

        return {"changed": False,
                "msg": "discovered %d inotify watches" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = item.split(" ", 1)
    type_ = parts[0].lower()
    path = parts[1] if len(parts) > 1 else ""

    st = ctx.stat(path)
    if not st or not st.exists:
        return {"changed": False,
                "msg": "path not found: " + path,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["stat", "-c", "%Y", path], mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "could not stat path: " + path,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ts = res.stdout.strip()
    if not ts or not ts.isdigit():
        return {"changed": False,
                "msg": "could not parse mtime for: " + path,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    mtime = int(ts)

    date_res = ctx.run(["date", "+%s"], mutates=False)
    if date_res.rc != 0:
        return {"changed": False,
                "msg": "could not get current time",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    now_s = date_res.stdout.strip()
    if not now_s or not now_s.isdigit():
        return {"changed": False,
                "msg": "could not parse current time",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    now = int(now_s)

    age = now - mtime

    levels = params.get("age_last_operation", [])
    warn = None
    crit = None
    for entry in levels:
        if len(entry) >= 3:
            w = entry[1]
            c = entry[2]
            if w != None:
                warn = w
            if c != None:
                crit = c

    state = "OK"
    if crit != None and age >= crit:
        state = "CRIT"
    elif warn != None and age >= warn:
        state = "WARN"

    verb = "Folder" if type_ == "folder" else "File"
    msg = "%s %s modified %ds ago" % (verb, path, age)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"age_last_operation": age},
                     "details": ""}}