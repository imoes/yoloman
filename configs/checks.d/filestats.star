# ===== translated: checkmk.filestats =====
# Read-only Starlark check module. Probes the same on-host source that the
# Checkmk agent plugin (mk_filestats) reads: the local filesystem.

_METRICS = ["file_count", "size", "age"]

def _fmt_size(n):
    if n == None:
        return "0 B"
    n = int(n)
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    i = 0
    val = float(n)
    while val >= 1024 and i < 5:
        val = val / 1024
        i = i + 1
    if i == 0:
        return "%d B" % n
    return "%f %s" % (val, units[i])

def _fmt_timespan(n):
    if n == None:
        return "0s"
    n = int(n)
    if n < 60:
        return "%ds" % n
    if n < 3600:
        return "%dm%ds" % (n / 60, n % 60)
    if n < 86400:
        return "%dh%dm" % (n / 3600, (n % 3600) / 60)
    return "%dd%dh" % (n / 86400, (n % 86400) / 3600)

def _clamp_levels(params, pkey):
    v = params.get(pkey)
    if v == None:
        return None
    if type(v) == "list":
        return tuple(v)
    if type(v) == "string":
        parts = v.split()
        return (float(parts[0]), float(parts[1]))
    return tuple(v)

def _level_state(value, params, pkey):
    lv = _clamp_levels(params, pkey)
    if lv == None:
        return "OK"
    w, c = lv
    if value >= c:
        return "CRIT"
    if value >= w:
        return "WARN"
    return "OK"

def _level_state_lower(value, params, pkey):
    lv = _clamp_levels(params, pkey)
    if lv == None:
        return "OK"
    w, c = lv
    if value <= c:
        return "CRIT"
    if value <= w:
        return "WARN"
    return "OK"

def _expand_paths(ctx, patterns):
    out = []
    for pat in patterns:
        res = ctx.run(["ls", "-d", pat], mutates=False)
        paths = []
        if res.rc == 0 and res.stdout != "":
            for ln in res.stdout.splitlines():
                p = ln.strip()
                if p != "":
                    paths.append(p)
        out.append((pat, paths))
    return out

def _stat_path(ctx, path):
    res = ctx.run(["stat", "-c", "%s|%Y|%F", path], mutates=False)
    if res.rc != 0:
        return None
    parts = res.stdout.strip().split("|")
    if len(parts) != 3:
        return None
    size_s, mtime_s, ftype = parts[0], parts[1], parts[2]
    size = int(size_s) if size_s.isdigit() else 0
    mtime = int(mtime_s) if mtime_s.isdigit() else 0
    age = 0
    if mtime > 0:
        now = ctx.run(["date", "+%s"], mutates=False)
        now_s = now.stdout.strip()
        now_i = int(now_s) if now_s.isdigit() else 0
        age = now_i - mtime
    return {"path": path, "size": size, "age": age, "type": ftype}

def _sum(lst):
    total = 0
    for x in lst:
        total = total + x
    return total

def _avg(lst):
    if len(lst) == 0:
        return 0
    return int(_sum(lst) / len(lst))

def main(ctx, params):
    if params.get("_discover"):
        patterns = params.get("paths", [])
        if len(patterns) == 0:
            return {"changed": False, "msg": "no paths configured",
                    "data": {"discovery": []}}
        expanded = _expand_paths(ctx, patterns)
        discovery = []
        for pat, paths in expanded:
            if len(paths) == 0:
                continue
            item = pat
            p = {"warn": 80, "crit": 90}
            discovery.append({"item": item, "params": p, "metrics": ["file_count", "size", "age"]})
        return {"changed": False,
                "msg": "discovered %d file groups" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE
    patterns = params.get("paths", [])
    if len(patterns) == 0:
        return {"changed": False,
                "msg": "no filestats paths configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    expanded = _expand_paths(ctx, patterns)
    item = params.get("item", "")
    chosen = None
    chosen_paths = []
    for pat, paths in expanded:
        if pat == item:
            chosen = pat
            chosen_paths = paths
            break
        if len(paths) > 0 and item in paths:
            chosen = pat
            chosen_paths = paths
            break
    if chosen == None:
        return {"changed": False,
                "msg": "no such file group",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if len(chosen_paths) == 0:
        return {"changed": False,
                "msg": "no files found for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    files = []
    for p in chosen_paths:
        st = _stat_path(ctx, p)
        if st != None:
            files.append(st)
    if len(files) == 0:
        return {"changed": False,
                "msg": "no readable files for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    count = len(files)
    ages = [f["age"] for f in files if f["age"] != None]
    sizes = [f["size"] for f in files if f["size"] != None]
    avg_age = _avg(ages)
    avg_size = _avg(sizes)
    msg = "Files: %d, avg age: %s, avg size: %s" % (count, _fmt_timespan(avg_age), _fmt_size(avg_size))

    metrics = {"file_count": count}
    if len(sizes) > 0:
        metrics["size_largest"] = max(sizes)
        metrics["size_smallest"] = min(sizes)
    if len(ages) > 0:
        metrics["age_oldest"] = max(ages)
        metrics["age_newest"] = min(ages)

    states = []
    sc = _level_state(count, params, "maxcount")
    if sc != "OK":
        states.append(sc)
    sc2 = _level_state_lower(count, params, "mincount")
    if sc2 != "OK":
        states.append(sc2)
    for key in ("size", "age"):
        fl = [f for f in files if f.get(key) != None]
        if len(fl) == 0:
            continue
        fl.sort(key = lambda f: f[key])
        smallest = fl[0][key]
        largest = fl[-1][key]
        newest = fl[0]["age"] if key == "age" else None
        oldest = fl[-1]["age"] if key == "age" else None
        candidates = [
            _level_state(smallest, params, "maxsize_smallest"),
            _level_state(largest, params, "maxsize_largest"),
            _level_state_lower(smallest, params, "minsize_smallest"),
            _level_state_lower(largest, params, "minsize_largest"),
        ]
        if key == "age":
            if newest != None:
                candidates.append(_level_state(newest, params, "maxage_newest"))
                candidates.append(_level_state_lower(newest, params, "minage_newest"))
            if oldest != None:
                candidates.append(_level_state(oldest, params, "maxage_oldest"))
                candidates.append(_level_state_lower(oldest, params, "minage_oldest"))
        for s in candidates:
            if s != "OK":
                states.append(s)

    state = "OK"
    if "CRIT" in states:
        state = "CRIT"
    elif "WARN" in states:
        state = "WARN"

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}