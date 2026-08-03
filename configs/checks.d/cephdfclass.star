def _render_bytes(n):
    # render bytes like Checkmk render.bytes
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    val = float(n)
    idx = 0
    while val >= 1024.0 and idx < len(units) - 1:
        val = val / 1024.0
        idx = idx + 1
    return "%d%s" % (int(val), units[idx])


def _parse_cephdf(raw_text):
    # raw_text is the JSON string from `ceph df` detail output
    if not raw_text:
        return None
    data = json.decode(raw_text)
    if data == None or type(data) != "dict":
        return None
    pools = {}
    raw_pools = data.get("pools")
    if raw_pools == None or type(raw_pools) != "list":
        return None
    for p in raw_pools:
        if type(p) != "dict":
            continue
        stats = {}
        raw_stats = p.get("stats")
        if raw_stats != None and type(raw_stats) == "dict":
            for k in raw_stats.keys():
                stats[str(k)] = int(raw_stats[k])
        name = str(p.get("name", ""))
        pools[name] = {"id": int(p.get("id", 0)), "name": name, "stats": stats}
    sbc = {}
    raw_classes = data.get("stats_by_class")
    if raw_classes != None and type(raw_classes) == "dict":
        for c in raw_classes.keys():
            rs = raw_classes[c]
            cs = {}
            if rs != None and type(rs) == "dict":
                for k in rs.keys():
                    cs[str(k)] = int(rs[k])
            sbc[str(c)] = cs
    return {"pools": pools, "stats_by_class": sbc}


def _discover(ctx):
    res = ctx.run(["ceph", "df", "detail", "--format=json"], mutates=False)
    if res.rc == 127 or (res.rc != 0 and res.stdout == ""):
        return {"changed": False, "msg": "no ceph found", "data": {"discovery": [], "host_labels": {}}}
    section = _parse_cephdf(res.stdout.strip())
    if section == None:
        return {"changed": False, "msg": "no ceph found", "data": {"discovery": []}}
    out = []
    for cls in section["stats_by_class"].keys():
        out.append({"item": cls, "params": {"warn": 80, "crit": 90}, "metrics": ["used_percent"]})
    host_labels = {}
    facts = ctx.facts()
    if facts.get("os_family") != None:
        host_labels["cmk/os_family"] = facts.get("os_family")
    return {"changed": False, "msg": "discovered %d classes" % len(out), "data": {"discovery": out, "host_labels": host_labels}}


def _check(ctx, params, item):
    res = ctx.run(["ceph", "df", "detail", "--format=json"], mutates=False)
    if res.rc == 127 or (res.rc != 0 and res.stdout == ""):
        return {"changed": False, "msg": "no ceph found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "ceph not installed"}}
    section = _parse_cephdf(res.stdout.strip())
    if section == None:
        return {"changed": False, "msg": "no ceph found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no ceph df data"}}
    stats = section["stats_by_class"].get(item)
    if stats == None:
        return {"changed": False, "msg": "no such class: " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": "class not found"}}
    mib = 1024.0 * 1024.0
    avail_mb = stats.get("total_avail_bytes", 0) / mib
    size_mb = stats.get("total_bytes", 0) / mib
    used_mb = size_mb - avail_mb
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    pct = (used_mb / size_mb * 100.0) if size_mb > 0 else 0.0
    if pct >= crit:
        state = "CRIT"
    elif pct >= warn:
        state = "WARN"
    else:
        state = "OK"
    details = "Size: %s, Used: %s (%f%%), Avail: %s" % (
        _render_bytes(size_mb * mib),
        _render_bytes(used_mb * mib),
        pct,
        _render_bytes(avail_mb * mib),
    )
    return {
        "changed": False,
        "msg": "Ceph Class %s: %s" % (item, details),
        "data": {
            "state": state,
            "metrics": {"used_percent": pct},
            "details": details,
        },
    }


def main(ctx, params):
    if params.get("_discover") == True:
        return _discover(ctx)
    item = params.get("item", "")
    return _check(ctx, params, item)