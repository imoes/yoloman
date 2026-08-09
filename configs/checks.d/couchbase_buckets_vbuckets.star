# Translated Checkmk check: couchbase_buckets_vbuckets (active + replica vBuckets)
# Source data: Couchbase REST API /admin/pools/default/buckets (JSON via curl).
#
# The Checkmk agent section `couchbase_buckets_vbuckets` is parsed from JSON lines
# produced by the Couchbase special agent. We reproduce the same data by querying
# the real Couchbase HTTP API directly (curl, read-only).

# Default thresholds (none are set in check_default_parameters; we use None = no level).

def _get_buckets_json(ctx, params, node, port):
    host = params.get("host", "localhost")
    username = params.get("username", "")
    password = params.get("password", "")
    url = "http://%s:%s/pools/default/buckets" % (node, port)
    args = ["curl", "-fsS", "-u", "%s:%s" % (username, password), "-H", "Accept: application/json", url]
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        if res.rc == 127:
            return None, "curl not installed"
        return None, "curl to %s failed (rc=%d): %s" % (url, res.rc, res.stderr.strip())
    if not res.stdout:
        return None, "empty response from %s" % url
    return json.decode(res.stdout), None


def _parse_buckets(json_data):
    out = {}
    if type(json_data) != "list":
        return out
    for entry in json_data:
        if type(entry) != "dict":
            continue
        name = entry.get("name")
        if name == None:
            continue
        stats = entry.get("stats")
        if stats == None or type(stats) != "dict":
            stats = {}
        # The Checkmk agent section delivers per-bucket vBucket counters directly;
        # we reproduce the same keys from the Couchbase bucket JSON.
        data = {
            "name": name,
            "vb_active_resident_items_ratio": entry.get("vb_active_resident_items_ratio"),
            "vb_active_itm_memory": entry.get("vb_active_itm_memory", stats.get("vb_active_itm_memory")),
            "vb_pending_num": entry.get("vb_pending_num", stats.get("vb_pending_num")),
            "vb_replica_num": entry.get("vb_replica_num", stats.get("vb_replica_num")),
            "vb_replica_itm_memory": entry.get("vb_replica_itm_memory", stats.get("vb_replica_itm_memory")),
        }
        out[name] = data
    return out


def _section(ctx, params):
    node = params.get("node", params.get("host", "localhost"))
    port = params.get("port", 8091)
    if port == None:
        port = 8091
    json_data, err = _get_buckets_json(ctx, params, node, port)
    if json_data == None:
        return None, err
    return _parse_buckets(json_data), None


def _grade(value, levels, higher_is_better):
    if levels == None or type(levels) != "list" or len(levels) < 2:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if higher_is_better:
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
    else:
        if value <= crit:
            return "CRIT"
        if value <= warn:
            return "WARN"
    return "OK"


def _highest_state(states):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = "OK"
    for s in states:
        if order.get(s, 3) > order.get(worst, 0):
            worst = s
    return worst


def main(ctx, params):
    if params.get("_discover"):
        section, err = _section(ctx, params)
        if section == None:
            return {"changed": False, "msg": err, "data": {"discovery": []}}
        discovery = []
        for item, data in section.items():
            metrics = []
            if data.get("vb_active_resident_items_ratio") != None:
                metrics.append("resident_items_ratio")
            if data.get("vb_active_itm_memory") != None:
                metrics.append("item_memory")
            if data.get("vb_pending_num") != None:
                metrics.append("pending_vbuckets")
            discovery.append({"item": item, "params": {}, "metrics": metrics})
        return {
            "changed": False,
            "msg": "discovered %d buckets" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    section, err = _section(ctx, params)
    if section == None:
        return {"changed": False, "msg": err, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = section.get(item)
    if data == None:
        msg = "no such bucket: %s (available: %s)" % (item, ", ".join(sorted(section.keys())))
        return {"changed": False, "msg": msg, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    states = []
    details_parts = []

    # resident_items_ratio (percent; higher = better -> warn at >=, crit at >=)
    ratio = data.get("vb_active_resident_items_ratio")
    if ratio != None:
        try_ratio = ratio
        levels = params.get("resident_items_ratio", (None, None))
        if type(levels) == "tuple":
            levels = list(levels)
        st = _grade(try_ratio, levels, True)
        states.append(st)
        metrics["resident_items_ratio"] = try_ratio
        details_parts.append("Resident items ratio: %d%%" % int(try_ratio))

    # item_memory (bytes; higher = better)
    mem = data.get("vb_active_itm_memory")
    if mem != None:
        try_mem = int(mem) if type(mem) in ("int", "float") and mem != None else 0
        levels = params.get("item_memory")
        if type(levels) == "tuple":
            levels = list(levels)
        st = _grade(try_mem, levels, True)
        states.append(st)
        metrics["item_memory"] = try_mem
        details_parts.append("Item memory: %d bytes" % try_mem)

    # pending_vbuckets (count; higher = better)
    pending = data.get("vb_pending_num")
    if pending != None:
        try_pending = int(pending) if type(pending) in ("int", "float") and pending != None else 0
        levels = params.get("vb_pending_num")
        if type(levels) == "tuple":
            levels = list(levels)
        st = _grade(try_pending, levels, True)
        states.append(st)
        metrics["pending_vbuckets"] = try_pending
        details_parts.append("Pending vBuckets: %d" % try_pending)

    state = _highest_state(states) if states else "OK"
    msg = "Bucket %s: %s" % (item, "; ".join(details_parts) if details_parts else "no metrics")
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "\n".join(details_parts),
        },
    }