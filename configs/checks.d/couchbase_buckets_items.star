def _last(samples, key):
    lst = samples.get(key)
    if lst == None or len(lst) == 0:
        return None
    return lst[len(lst) - 1]

def _check_levels(value, levels):
    if levels == None:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def _worst(a, b):
    rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if rank.get(a, 0) >= rank.get(b, 0):
        return a
    return b

def _build_argv(user, password, url):
    base = ["curl", "-s", "--connect-timeout", "10", "-m", "30"]
    if user:
        base = base + ["-u", user + ":" + password]
    return base + [url]

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 8091)
    user = params.get("user", "")
    password = params.get("password", "")
    ssl = params.get("ssl", False)

    scheme = "https" if ssl else "http"
    base_url = "%s://%s:%d" % (scheme, host, int(port))

    if params.get("_discover"):
        res = ctx.run(_build_argv(user, password, base_url + "/pools/default/buckets"), mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "failed to query Couchbase bucket list",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        if type(data) != "list":
            return {"changed": False, "msg": "unexpected response from Couchbase",
                    "data": {"discovery": []}}
        out = []
        for b in data:
            name = b.get("name", "")
            if not name:
                continue
            out.append({
                "item": name,
                "params": {},
                "metrics": ["items_count", "disk_write_ql", "fetched_items", "disk_fill_rate", "disk_drain_rate"],
            })
        return {"changed": False, "msg": "discovered %d buckets" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    url = base_url + "/pools/default/buckets/" + item + "/stats"
    res = ctx.run(_build_argv(user, password, url), mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "query failed for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout.strip():
        return {"changed": False, "msg": "no data returned for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = json.decode(res.stdout)
    samples = parsed.get("op", {}).get("samples", {})

    state = "OK"
    metrics = {}
    parts = []

    total_items = _last(samples, "curr_items_tot")
    if total_items != None:
        v = int(total_items)
        metrics["items_count"] = v
        state = _worst(state, _check_levels(v, params.get("curr_items_tot")))
        parts.append("Total items in vBuckets: %d" % v)

    write_queue = _last(samples, "disk_write_queue")
    if write_queue != None:
        v = int(write_queue)
        metrics["disk_write_ql"] = v
        state = _worst(state, _check_levels(v, params.get("disk_write_ql")))
        parts.append("Items in disk write queue: %d" % v)

    fetched = _last(samples, "ep_bg_fetched")
    if fetched != None:
        v = int(fetched)
        metrics["fetched_items"] = v
        state = _worst(state, _check_levels(v, params.get("fetched_items")))
        parts.append("Items fetched from disk: %d" % v)

    fill = _last(samples, "ep_diskqueue_fill")
    if fill != None:
        v = float(fill)
        metrics["disk_fill_rate"] = v
        state = _worst(state, _check_levels(v, params.get("disk_fill_rate")))
        parts.append("Disk queue fill rate: %f/s" % v)

    drain = _last(samples, "ep_diskqueue_drain")
    if drain != None:
        v = float(drain)
        metrics["disk_drain_rate"] = v
        state = _worst(state, _check_levels(v, params.get("disk_drain_rate")))
        parts.append("Disk queue drain rate: %f/s" % v)

    if not parts:
        return {"changed": False, "msg": "no item stats available for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": ", ".join(parts),
            "data": {"state": state, "metrics": metrics, "details": ""}}