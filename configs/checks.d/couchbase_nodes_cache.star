def _rate(store, name, timestamp, value):
    prev = store.get(name)
    if prev == None:
        store[name] = {"t": timestamp, "v": value}
        return None
    dt = timestamp - prev["t"]
    dv = value - prev["v"]
    store[name] = {"t": timestamp, "v": value}
    if dt <= 0:
        return None
    if dv < 0:
        return None
    rate = float(dv) * 1.0 / float(dt)
    return rate


def _check_levels(value, levels, boundaries):
    state = "OK"
    warn, crit = levels[0], levels[1]
    lower, upper = boundaries[0], boundaries[1]

    if lower != None and value < lower:
        if crit != None and value <= crit:
            state = "CRIT"
        elif warn != None and value <= warn:
            state = "WARN"
    if upper != None and value > upper:
        if crit != None and value >= crit:
            state = "CRIT"
        elif warn != None and value >= warn:
            state = "WARN"
    return state


def _worst_state(states):
    result = "OK"
    for s in states:
        if s == "CRIT":
            result = "CRIT"
        elif s == "WARN" and result != "CRIT":
            result = "WARN"
    return result


def _time_now(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.stdout == None or len(res.stdout) == 0:
        return 0
    stripped = res.stdout.strip()
    if stripped.isdigit():
        return int(stripped)
    return 0


def main(ctx, params):
    couchctl = ctx.run(["couchctl", "version"], mutates=False)
    if couchctl.rc == 127 or couchctl.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "couchbase not installed (couchctl missing)",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "couchbase not installed (couchctl missing)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats = ctx.run(["couchctl", "stats", "--json"], mutates=False)
    if stats.rc != 0 or stats.stdout == None or len(stats.stdout) == 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no couchbase stats available",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no couchbase stats available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    decoded = json.decode(stats.stdout)
    section = {}
    if type(decoded) == "list":
        for node in decoded:
            if type(node) == "string" and len(node) > 0:
                d = json.decode(node)
                if type(d) == "dict" and d.get("name") != None:
                    section[d["name"]] = d
            elif type(node) == "dict" and node.get("name") != None:
                section[node["name"]] = node
    elif type(decoded) == "dict" and decoded.get("name") != None:
        section[decoded["name"]] = decoded

    if params.get("_discover"):
        discovery = []
        for item, data in section.items():
            if type(data) == "dict" and "get_hits" in data and "ep_bg_fetched" in data:
                discovery.append({
                    "item": item,
                    "params": {"cache_misses": (None, None), "cache_hits": (None, None)},
                    "metrics": ["cache_misses_rate", "cache_hit_ratio"],
                })
        return {"changed": False,
                "msg": "discovered %d couchbase cache items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    misses = data.get("ep_bg_fetched")
    hits = data.get("get_hits")
    if misses == None or hits == None:
        return {"changed": False,
                "msg": "no cache counters available for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    store = {}
    timestamp = _time_now(ctx)
    total = misses + hits
    if total != 0:
        hit_perc = (float(hits) * 100.0) * 1.0 / float(total)
    else:
        hit_perc = 100.0
    miss_rate = _rate(store, "cache_misses_" + item, timestamp, misses)

    cache_misses_levels = params.get("cache_misses", (None, None))
    cache_hits_levels = params.get("cache_hits", (None, None))

    details = []
    metrics = {}

    if miss_rate != None:
        miss_state = _check_levels(miss_rate, cache_misses_levels, (None, None))
        metrics["cache_misses_rate"] = miss_rate
        details.append("Cache misses rate: %s/s (%s)" % (str(miss_rate), miss_state))
    else:
        miss_state = "OK"
        details.append("Cache misses rate: insufficient data")

    hit_state = _check_levels(hit_perc, cache_hits_levels, (0, 100))
    metrics["cache_hit_ratio"] = hit_perc
    details.append("Cache hits: %s%% (%s)" % (str(hit_perc), hit_state))

    worst = _worst_state([miss_state, hit_state])

    miss_str = str(miss_rate) if miss_rate != None else "?"
    msg = "Cache: hits=%s%%, misses=%s/s" % (str(hit_perc), miss_str)

    return {"changed": False, "msg": msg,
            "data": {"state": worst,
                     "metrics": metrics,
                     "details": "; ".join(details)}}