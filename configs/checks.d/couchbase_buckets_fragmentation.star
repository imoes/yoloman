# Translated Checkmk check: couchbase_buckets_fragmentation
# Couchbase Bucket fragmentation monitor (read-only Starlark module).

BUCKETS_KEY = "buckets"

def _couchbase_data(ctx, host, community):
    # Couchbase exposes its metrics via an HTTP (REST) API on port 8091.
    # Query the buckets endpoint using curl with basic auth-less access.
    res = ctx.run(
        ["curl", "-sS", "-u", ":", "-m", "10",
         "http://" + host + ":8091/pools/default/buckets"],
        mutates=False,
    )
    return res

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "")
        res = _couchbase_data(ctx, host, community)
        # Not installed / not reachable -> empty discovery.
        if res.rc != 0:
            return {"changed": False, "msg": "couchbase not reachable",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout) if res.stdout else []
        if not isinstance(data, list):
            return {"changed": False, "msg": "unexpected couchbase response",
                    "data": {"discovery": []}}
        out = []
        for bucket in data:
            if not isinstance(bucket, dict):
                continue
            name = bucket.get("name", "")
            if not name:
                continue
            # Only discover buckets that report fragmentation data.
            has_docs = "couch_docs_fragmentation" in bucket
            has_views = "couch_views_fragmentation" in bucket
            if not (has_docs or has_views):
                continue
            metrics = []
            if has_docs:
                metrics.append("docs_fragmentation")
            if has_views:
                metrics.append("views_fragmentation")
            out.append({"item": name,
                        "params": {"docs": (80, 90), "views": (80, 90)},
                        "metrics": metrics})
        return {"changed": False, "msg": "discovered %d buckets" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "")
    res = _couchbase_data(ctx, host, community)
    # Data ungatherable -> UNKNOWN, not OK.
    if res.rc != 0 or not res.stdout:
        return {"changed": False,
                "msg": "couchbase not reachable: " + str(res.stderr),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if not isinstance(data, list):
        return {"changed": False,
                "msg": "unexpected couchbase response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    bucket = None
    for b in data:
        if isinstance(b, dict) and b.get("name", "") == item:
            bucket = b
            break
    if bucket == None:
        return {"changed": False,
                "msg": "no such bucket: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details = ""
    states = []
    docs_frag = bucket.get("couch_docs_fragmentation")
    if docs_frag != None:
        docs_pct = _to_percent(docs_frag)
        if docs_pct != None:
            metrics["docs_fragmentation"] = docs_pct
            dlevels = params.get("docs", (80, 90))
            states.append(_grade(docs_pct, dlevels))
            details = details + "Documents fragmentation: " + str(docs_pct) + "%\n"
    views_frag = bucket.get("couch_views_fragmentation")
    if views_frag != None:
        views_pct = _to_percent(views_frag)
        if views_pct != None:
            metrics["views_fragmentation"] = views_pct
            vlevels = params.get("views", (80, 90))
            states.append(_grade(views_pct, vlevels))
            details = details + "Views fragmentation: " + str(views_pct) + "%\n"

    if len(states) == 0:
        return {"changed": False,
                "msg": "no fragmentation data for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = _worst(states)
    msg = item + " fragmentation ok"
    if state == "WARN":
        msg = item + " fragmentation WARN"
    elif state == "CRIT":
        msg = item + " fragmentation CRIT"
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}

def _to_percent(val):
    # Couchbase reports fragmentation as a percentage number.
    if isinstance(val, (int, float)):
        return float(val)
    if isinstance(val, str):
        s = val.strip().replace("%", "")
        try_digits = s
        if try_digits.lstrip("-").isdigit():
            return float(try_digits)
        # Allow simple decimal strings.
        parts = try_digits.split(".")
        if len(parts) == 2 and parts[0].lstrip("-").isdigit() and parts[1].isdigit():
            return float(try_digits)
    return None

def _grade(value, levels):
    warn = levels[0] if len(levels) > 0 else 80
    crit = levels[1] if len(levels) > 1 else 90
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _worst(states):
    rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = "OK"
    for s in states:
        if rank.get(s, 3) > rank.get(worst, 0):
            worst = s
    return worst