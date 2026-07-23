def _get_latest(samples):
    if len(samples) == 0:
        return None
    return samples[len(samples) - 1]

def _url(host, port, path):
    return "http://" + host + ":" + str(port) + path

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 8091)
    user = params.get("user", "admin")
    password = params.get("password", "")

    if params.get("_discover"):
        list_url = _url(host, port, "/pools/default/buckets")
        res = ctx.run(["curl", "-s", "-u", user + ":" + password, list_url], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "could not list buckets",
                    "data": {"discovery": []}}
        buckets = json.decode(res.stdout)
        if type(buckets) != "list":
            return {"changed": False, "msg": "unexpected bucket list format",
                    "data": {"discovery": []}}
        out = []
        for bucket in buckets:
            name = bucket.get("name", "")
            if not name:
                continue
            stats_url = _url(host, port, "/pools/default/buckets/" + name + "/stats")
            sr = ctx.run(["curl", "-s", "-u", user + ":" + password, stats_url], mutates=False)
            if sr.rc != 0 or not sr.stdout.strip():
                continue
            sd = json.decode(sr.stdout)
            samples = sd.get("op", {}).get("samples", {})
            if "ep_cache_miss_rate" not in samples:
                continue
            out.append({
                "item": name,
                "params": {},
                "metrics": ["cache_misses_rate"],
            })
        return {"changed": False,
                "msg": "discovered %d buckets with cache stats" % len(out),
                "data": {"discovery": out}}

    # check mode
    item = params.get("item", "")
    levels = params.get("cache_misses", None)
    warn = levels[0] if (levels != None and len(levels) >= 2) else None
    crit = levels[1] if (levels != None and len(levels) >= 2) else None

    stats_url = _url(host, port, "/pools/default/buckets/" + item + "/stats")
    res = ctx.run(["curl", "-s", "-u", user + ":" + password, stats_url], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "failed to get stats for bucket: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sd = json.decode(res.stdout)
    samples = sd.get("op", {}).get("samples", {})
    miss_samples = samples.get("ep_cache_miss_rate", [])
    latest = _get_latest(miss_samples)

    if latest == None:
        return {"changed": False,
                "msg": "ep_cache_miss_rate not available for bucket: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    miss_rate = float(latest)
    state = "OK"
    if (warn != None) and (crit != None):
        if miss_rate >= crit:
            state = "CRIT"
        elif miss_rate >= warn:
            state = "WARN"
    elif warn != None:
        if miss_rate >= warn:
            state = "WARN"

    return {
        "changed": False,
        "msg": "Cache misses: %g/s" % miss_rate,
        "data": {
            "state": state,
            "metrics": {"cache_misses_rate": miss_rate},
            "details": "",
        },
    }