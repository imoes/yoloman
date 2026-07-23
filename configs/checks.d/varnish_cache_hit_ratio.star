def main(ctx, params):
    # Discovery mode: detect if varnish data is available via varnishstat
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "varnishstat not available or no data",
                    "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        has_cache_hit = False
        has_cache_miss = False
        for line in lines:
            fields = line.split()
            if len(fields) >= 3:
                name = fields[2] if len(fields) > 3 else fields[0].split('.')[-1]
                if name == "cache_hit":
                    has_cache_hit = True
                if name == "cache_miss":
                    has_cache_miss = True
        
        if has_cache_hit and has_cache_miss:
            return {"changed": False, "msg": "discovered Varnish Cache Hit Ratio service",
                    "data": {"discovery": [{"item": "", "params": {"levels_lower": (70.0, 60.0)}, 
                                           "metrics": ["cache_hit_ratio"]}]}}
        return {"changed": False, "msg": "no varnish cache hit/miss data",
                "data": {"discovery": []}}

    # Check mode: compute cache hit ratio
    res = ctx.run(["varnishstat", "-1"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "varnishstat failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cache_hit = None
    cache_miss = None

    lines = res.stdout.splitlines()
    for line in lines:
        fields = line.split()
        if len(fields) < 3:
            continue
        # Extract metric name from third field (e.g., "MAIN.cache_hit")
        metric_name = fields[2].split('.')[-1]
        value_str = fields[0]
        if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
            value = int(value_str)
        else:
            continue
        
        if metric_name == "cache_hit":
            cache_hit = value
        if metric_name == "cache_miss":
            cache_miss = value

    # Compute ratio
    cache_hit_ratio = 0.0
    if cache_hit != None and cache_miss != None:
        total = cache_hit + cache_miss
        if total > 0:
            cache_hit_ratio = 100.0 * cache_hit / total

    warn, crit = params.get("levels_lower", (70.0, 60.0))
    
    state = "OK"
    if cache_hit_ratio <= crit:
        state = "CRIT"
    elif cache_hit_ratio <= warn:
        state = "WARN"
    
    msg = "Cache hit ratio: %f%%" % cache_hit_ratio

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"cache_hit_ratio": cache_hit_ratio},
                     "details": ""}}