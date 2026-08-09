# couchbase_nodes_operations_total: read-only Starlark check (Couchbase Total Operations)
# Gathers per-node ops from the Couchbase REST API and reports total ops/s.

def _num(x):
    if x == None or x == "":
        return 0.0
    s = str(x)
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if s.isdigit():
        v = float(s)
        return -v if neg else v
    dot = s.rsplit(".", 1)
    if len(dot) == 2 and dot[0].isdigit() and dot[1].isdigit():
        v = float(s)
        return -v if neg else v
    return 0.0

def _fetch_nodes(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 8091)
    user = params.get("username", "Administrator")
    pw = params.get("password", "password")
    base = "http://%s:%s" % (host, port)
    if not user:
        url = base + "/pools/default/buckets/default/nodes"
    else:
        url = base + "/pools/default/buckets/default/nodes"
    res = ctx.run(["curl", "-s", "-k", "-u", "%s:%s" % (user, pw), url], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    data = json.decode(res.stdout) if res.stdout.strip().startswith("[") or res.stdout.strip().startswith("{") else None
    if data == None:
        return None
    nodes = {}
    if type(data) == "list":
        for n in data:
            hostname = n.get("hostname", "") if type(n) == "dict" else ""
            if hostname == "":
                continue
            is_stats = n.get("interesting_stats", {}) if type(n) == "dict" else {}
            if type(is_stats) != "dict":
                is_stats = {}
            ops_hits = is_stats.get("op_hits", [])
            ops_misses = is_stats.get("op_misses", [])
            ops_updates = is_stats.get("op_updates", [])
            hit_rate = 0.0
            miss_rate = 0.0
            upd_rate = 0.0
            if type(ops_hits) == "list" and len(ops_hits) >= 2:
                second = ops_hits[-1]
                if type(second) == "list" and len(second) >= 2:
                    hit_rate = _num(second[1])
            if type(ops_misses) == "list" and len(ops_misses) >= 2:
                second = ops_misses[-1]
                if type(second) == "list" and len(second) >= 2:
                    miss_rate = _num(second[1])
            if type(ops_updates) == "list" and len(ops_updates) >= 2:
                second = ops_updates[-1]
                if type(second) == "list" and len(second) >= 2:
                    upd_rate = _num(second[1])
            nodes[hostname] = hit_rate + miss_rate + upd_rate
    return nodes

def main(ctx, params):
    if params.get("_discover"):
        nodes = _fetch_nodes(ctx, params)
        if not nodes:
            return {"changed": False, "msg": "no couchbase nodes found", "data": {"discovery": []}}
        out = []
        for node in sorted(nodes.keys()):
            out.append({"item": node, "params": {"ops": [80.0, 90.0]}, "metrics": ["op_s"]})
        out.append({"item": "", "params": {"ops": [80.0, 90.0]}, "metrics": ["op_s"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    nodes = _fetch_nodes(ctx, params)
    if not nodes:
        return {
            "changed": False,
            "msg": "no couchbase nodes found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    total = 0.0
    for v in nodes.values():
        total += v
    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)
    levels = params.get("ops", [warn, crit])
    if type(levels) == "list" and len(levels) >= 2:
        warn = _num(levels[0])
        crit = _num(levels[1])
    elif type(levels) == "dict" and levels.get("levels_upper") != None:
        lvls = levels.get("levels_upper")
        if type(lvls) == "list" and len(lvls) >= 2:
            warn = _num(lvls[0])
            crit = _num(lvls[1])
    state = "OK"
    if total >= crit:
        state = "CRIT"
    elif total >= warn:
        state = "WARN"
    return {
        "changed": False,
        "msg": "Couchbase Total Operations: %f/s" % total,
        "data": {
            "state": state,
            "metrics": {"op_s": total},
            "details": "",
        },
    }