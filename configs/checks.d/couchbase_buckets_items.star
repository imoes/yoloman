# Checkmk check → read-only Starlark check module
# Source: cmk/plugins/couchbase/agent_based/couchbase_buckets_items.py

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", "8091")

    if params.get("_discover"):
        res = ctx.run(
            ["curl", "-fsS", "http://%s:%s/pools/default/buckets" % (host, port)],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no couchbase buckets found",
                    "data": {"discovery": []}}
        buckets = json.decode(res.stdout)
        if type(buckets) != "list":
            return {"changed": False, "msg": "unexpected couchbase response",
                    "data": {"discovery": []}}
        out = []
        for b in buckets:
            name = b.get("name", "")
            if name == "":
                continue
            out.append({"item": name, "params": {}, "metrics": ["items_count",
                         "disk_write_ql", "fetched_items",
                         "disk_fill_rate", "disk_drain_rate"]})
        return {"changed": False, "msg": "discovered %d buckets" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False,
                "msg": "no couchbase bucket selected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats_url = "http://%s:%s/pools/default/buckets/%s/stats" % (host, port, item)
    res = ctx.run(["curl", "-fsS", stats_url], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False,
                "msg": "couchbase bucket '%s' not reachable" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats = json.decode(res.stdout)
    if type(stats) != "dict" or "op" not in stats:
        return {"changed": False,
                "msg": "couchbase stats not available for '%s'" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    samples = stats.get("op", {}).get("samples", {})

    def last(key):
        arr = samples.get(key, [])
        if len(arr) == 0:
            return None
        return arr[-1]

    total_items = last("curr_items_tot")
    write_queue = last("disk_write_queue")
    fetched = last("ep_bg_fetched")
    queue_fill = last("ep_diskqueue_fill")
    queue_drain = last("ep_diskqueue_drain")

    warn = params.get("warn", None)
    crit = params.get("crit", None)

    metrics = {}
    details_parts = []
    state = "OK"

    def grade(value, w, c, higher=True):
        s = "OK"
        if value == None:
            return s
        if w != None and c != None:
            if (higher and value >= c) or (not higher and value <= c):
                s = "CRIT"
            elif (higher and value >= w) or (not higher and value <= w):
                s = "WARN"
        return s

    def worst(a, b):
        order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
        if order.get(a, 3) >= order.get(b, 3):
            return a
        return b

    if total_items != None:
        total_items = int(total_items)
        metrics["items_count"] = total_items
        details_parts.append("Total items: %d" % total_items)
        state = worst(state, grade(total_items, warn, crit, True))

    if write_queue != None:
        write_queue = int(write_queue)
        metrics["disk_write_ql"] = write_queue
        details_parts.append("Write queue: %d" % write_queue)
        state = worst(state, grade(write_queue, warn, crit, True))

    if fetched != None:
        fetched = int(fetched)
        metrics["fetched_items"] = fetched
        details_parts.append("Fetched: %d" % fetched)
        state = worst(state, grade(fetched, warn, crit, True))

    if queue_fill != None:
        queue_fill = float(queue_fill)
        metrics["disk_fill_rate"] = queue_fill
        details_parts.append("Fill rate: %f/s" % queue_fill)
        state = worst(state, grade(queue_fill, warn, crit, True))

    if queue_drain != None:
        queue_drain = float(queue_drain)
        metrics["disk_drain_rate"] = queue_drain
        details_parts.append("Drain rate: %f/s" % queue_drain)
        state = worst(state, grade(queue_drain, warn, crit, True))

    msg = item + ": " + ", ".join(details_parts) if details_parts else item
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics,
                     "details": "; ".join(details_parts)}}