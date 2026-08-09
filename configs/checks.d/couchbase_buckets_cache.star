# Copyright (C) 2019 Checkmk GmbH - License: GNU General Public License v2
# Translated to read-only Starlark for the yolo-man agent.

# This check monitors Couchbase bucket cache miss rates.
# It gathers data via the Couchbase REST API (the same source the
# Checkmk agent section reads from when the Couchbase agent plugin
# queries the cluster).

# Default threshold for cache miss rate (per second).
DEFAULT_CACHE_MISSES_WARN = 100
DEFAULT_CACHE_MISSES_CRIT = 200

def _couchbase_get(ctx, host, port, username, password, path):
    """Perform a read-only GET against the Couchbase REST API.
    Returns the decoded JSON body, or None if the request failed."""
    url = "http://%s:%s%s" % (host, port, path)
    res = ctx.run(
        ["curl", "-s", "-f", "-u", "%s:%s" % (username, password), url],
        mutates=False,
        ok_codes=[0, 22],
    )
    if res.rc != 0:
        return None
    if res.stdout == "":
        return None
    decoded = json.decode(res.stdout)
    return decoded

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 8091)
    username = params.get("username", "Administrator")
    password = params.get("password", "password")
    item = params.get("item", "")

    # --- Discovery mode ---
    if params.get("_discover"):
        # Probe that Couchbase is actually running.
        buckets_body = _couchbase_get(ctx, host, port, username, password, "/pools/default/buckets")
        if buckets_body == None:
            return {"changed": False, "msg": "Couchbase not reachable",
                    "data": {"discovery": [], "host_labels": {}}}
        if type(buckets_body) != "list":
            return {"changed": False, "msg": "Couchbase returned unexpected data",
                    "data": {"discovery": []}}
        discovery = []
        for b in buckets_body:
            name = b.get("name")
            if name == None:
                continue
            stats_path = "/pools/default/stats?/buckets/" + name + "%2Fops%2F%7B%7D"
            stats_body = _couchbase_get(ctx, host, port, username, password, stats_path)
            if stats_body == None:
                continue
            bucket_stats = {}
            if type(stats_body) == "dict":
                bucket_stats = stats_body.get("", {})
            if "ep_cache_miss_rate" not in bucket_stats:
                continue
            discovery.append({
                "item": name,
                "params": {},
                "metrics": ["cache_misses_rate"],
            })
        return {"changed": False, "msg": "discovered %d buckets" % len(discovery),
                "data": {"discovery": discovery}}

    # --- Check mode ---
    # Gather all bucket cache data.
    buckets_body = _couchbase_get(ctx, host, port, username, password, "/pools/default/buckets")
    if buckets_body == None:
        return {"changed": False, "msg": "Couchbase not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Couchbase API unreachable"}}
    if type(buckets_body) != "list":
        return {"changed": False, "msg": "Couchbase returned unexpected data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Couchbase API returned unexpected format"}}

    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no bucket item specified"}}

    # Find the bucket with the matching name.
    target_bucket = None
    for b in buckets_body:
        if b.get("name") == item:
            target_bucket = b
            break
    if target_bucket == None:
        return {"changed": False, "msg": "no such bucket: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "bucket not found"}}

    # Query per-bucket stats for cache miss rates.
    stats_path = "/pools/default/stats?/buckets/" + item + "%2Fops%2F%7B%7D"
    stats_body = _couchbase_get(ctx, host, port, username, password, stats_path)
    if stats_body == None:
        return {"changed": False, "msg": "no stats for " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "stats endpoint unreachable"}}

    bucket_stats = {}
    if type(stats_body) == "dict":
        bucket_stats = stats_body.get("", {})
    if "ep_cache_miss_rate" not in bucket_stats:
        return {"changed": False, "msg": "no cache miss data for " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "ep_cache_miss_rate not available"}}

    vals = bucket_stats["ep_cache_miss_rate"]
    miss_rate = None
    if type(vals) == "list" and len(vals) > 0:
        last = vals[len(vals) - 1]
        if type(last) == "list" and len(last) > 1:
            miss_rate = last[1]
        elif type(last) in ("int", "float"):
            miss_rate = last
    if miss_rate == None:
        return {"changed": False, "msg": "no cache miss value for " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "ep_cache_miss_rate has no usable value"}}

    # Apply threshold levels from params (Checkmk default: empty => use defaults)
    levels = params.get("cache_misses")
    warn = DEFAULT_CACHE_MISSES_WARN
    crit = DEFAULT_CACHE_MISSES_CRIT
    if type(levels) == "list" and len(levels) == 2:
        warn = levels[0]
        crit = levels[1]
    elif type(levels) == "dict":
        warn = levels.get("warn", DEFAULT_CACHE_MISSES_WARN)
        crit = levels.get("crit", DEFAULT_CACHE_MISSES_CRIT)

    # Grade: upper levels -> WARN if >= warn, CRIT if >= crit
    state = "OK"
    if miss_rate >= crit:
        state = "CRIT"
    elif miss_rate >= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "Cache misses: %s/s" % str(miss_rate),
            "data": {
                "state": state,
                "metrics": {"cache_misses_rate": miss_rate},
                "details": "Bucket %s ep_cache_miss_rate: %s/s (warn=%s, crit=%s)" % (
                    str(item), str(miss_rate), str(warn), str(crit)),
            }}