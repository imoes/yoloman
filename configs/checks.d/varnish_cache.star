def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "--json"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        main_data = data.get("varnish", {}).get("MAIN", data.get("varnish", data))
        if "cache_miss" in main_data or "cache_miss" in data.get("MAIN", {}):
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": ["cache_hit_rate", "cache_miss_rate", "cache_hitpass_rate"]}]}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    res = ctx.run(["varnishstat", "--json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "cannot read varnish statistics",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    main_data = data.get("varnish", {}).get("MAIN", data.get("varnish", data))
    miss_val = main_data.get("cache_miss", {}).get("value") if isinstance(main_data.get("cache_miss"), dict) else main_data.get("cache_miss")
    hit_val  = main_data.get("cache_hit", {}).get("value")  if isinstance(main_data.get("cache_hit"), dict) else main_data.get("cache_hit")
    hitpass_val = main_data.get("cache_hitpass", {}).get("value") if isinstance(main_data.get("cache_hitpass"), dict) else main_data.get("cache_hitpass")

    if miss_val == None or hit_val == None or hitpass_val == None:
        return {"changed": False, "msg": "missing expected keys (cache_miss, cache_hit, cache_hitpass)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    miss_rate = main_data.get("cache_miss", {}).get("rate") if isinstance(main_data.get("cache_miss"), dict) else None
    hit_rate  = main_data.get("cache_hit", {}).get("rate")  if isinstance(main_data.get("cache_hit"), dict) else None
    hitpass_rate = main_data.get("cache_hitpass", {}).get("rate") if isinstance(main_data.get("cache_hitpass"), dict) else None

    if miss_rate == None:
        miss_rate = miss_val
    if hit_rate == None:
        hit_rate = hit_val
    if hitpass_rate == None:
        hitpass_rate = hitpass_val

    total = hit_val + miss_val
    hit_ratio = 100.0 * hit_val / total if total > 0 else 0.0

    metrics = {
        "cache_hit_rate": float(hit_rate) if hit_rate != None else 0.0,
        "cache_miss_rate": float(miss_rate) if miss_rate != None else 0.0,
        "cache_hitpass_rate": float(hitpass_rate) if hitpass_rate != None else 0.0,
        "cache_hit_ratio": float(hit_ratio)
    }

    state = "OK"
    msg = "Cache hit: %f%%, Hits: %f/s, Misses: %f/s, Hitpass: %f/s" % (
        hit_ratio,
        metrics["cache_hit_rate"],
        metrics["cache_miss_rate"],
        metrics["cache_hitpass_rate"]
    )

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
