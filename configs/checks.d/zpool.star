def _pow(base, exp):
    result = 1
    for _ in range(exp):
        result = result * base
    return result


def _mb(val):
    idx = 0
    for i, ch in enumerate(val):
        idx = i
        if ch not in "0123456789.-":
            break
    num = float(val[:idx])
    unit_str = val[idx:].lstrip().lower()
    units = ["b", "k", "m", "g", "t", "p"]
    unit = units.index(unit_str)
    return num * _pow(1024, unit - 2)


def _canonize_header_entry(entry):
    if entry == "used":
        return "alloc"
    if entry == "avail":
        return "free"
    return entry


def _parse_zpool(output):
    if not output:
        return None
    lines = output.splitlines()
    if not lines:
        return None
    raw_header = lines[0].split()
    header = [_canonize_header_entry(item.lower()) for item in raw_header]
    section = {}
    for line in lines[1:]:
        fields = line.split()
        if len(fields) < len(header):
            continue
        entry = dict(zip(header, fields))
        name = entry.get("name", "")
        if not name or "size" not in entry or "free" not in entry:
            continue
        size_mb = _mb(entry["size"])
        free_mb = _mb(entry["free"])
        section[name] = (name, size_mb, free_mb, 0)
    return section


def _df_check(item, section, params):
    warn = params.get("warn", None)
    crit = params.get("crit", None)
    levels = params.get("levels", None)
    if levels != None:
        warn = levels[0]
        crit = levels[1]
    if warn == None:
        warn = 90
    if crit == None:
        crit = 95
    if item not in section:
        return (None, [], "no such pool: " + item, "UNKNOWN")
    name, size_mb, free_mb, _ = section[item]
    used_mb = size_mb - free_mb
    if size_mb <= 0:
        pct = 0
    else:
        pct = (used_mb / size_mb) * 100
    state = "OK"
    if pct >= crit:
        state = "CRIT"
    elif pct >= warn:
        state = "WARN"
    metrics = {"used_percent": pct}
    details = "Size: %f MB, Used: %f MB, Avail: %f MB" % (size_mb, used_mb, free_mb)
    msg = "%s %d%% used" % (item, int(pct))
    return (state, metrics, msg, details)


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["zpool", "list", "-H"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no zpool pools found",
                    "data": {"discovery": []}}
        section = _parse_zpool(res.stdout)
        if not section:
            return {"changed": False, "msg": "no zpool pools found",
                    "data": {"discovery": []}}
        out = []
        for name in section:
            out.append({"item": name,
                        "params": {"levels": [90, 95]},
                        "metrics": ["used_percent"]})
        return {"changed": False, "msg": "discovered %d pools" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["zpool", "list", "-H"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no zpool pools found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_zpool(res.stdout)
    if not section:
        return {"changed": False, "msg": "no zpool pools found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state, metrics, msg, details = _df_check(item, section, params)
    if state == None:
        return {"changed": False, "msg": msg,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": details}}
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}