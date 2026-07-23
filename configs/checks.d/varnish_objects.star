def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "varnishstat failed", 
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "varnishstat returned empty output",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        
        main_data = data.get("MAIN", {})
        if main_data == None:
            return {"changed": False, "msg": "no MAIN section in varnishstat output",
                    "data": {"discovery": []}}
        
        if main_data.get("n_expired") != None and main_data.get("n_lru_nuked") != None:
            return {
                "changed": False,
                "msg": "discovered Varnish Objects service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["n_expired_rate", "n_lru_nuked_rate", "n_lru_moved_rate"]}]}
            }
        return {"changed": False, "msg": "discovered 0 services", "data": {"discovery": []}}
    
    # Check mode (single-service)
    res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "varnishstat failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if not res.stdout:
        return {
            "changed": False,
            "msg": "varnishstat returned empty output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    data = json.decode(res.stdout)
    
    main_data = data.get("MAIN", {})
    if main_data == None:
        return {
            "changed": False,
            "msg": "no MAIN section in varnishstat output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    keys = ["n_expired", "n_lru_nuked", "n_lru_moved"]
    metrics = {}
    
    for key in keys:
        entry = main_data.get(key)
        if entry == None:
            continue
        value = entry.get("value")
        if value == None:
            continue
        perf_name = "varnish_%s_rate" % key
        if perf_name.startswith("varnish_n_"):
            perf_name = perf_name.replace("n_", "objects_")
        metrics[perf_name] = float(value)
    
    state = "OK"
    msg_parts = []
    for key in keys:
        entry = main_data.get(key)
        if entry == None:
            continue
        value = entry.get("value")
        if value == None:
            continue
        unit = "/s"
        msg_parts.append("%s: %d %s" % (key, value, unit))
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {"state": state, "metrics": metrics, "details": ""}
    }