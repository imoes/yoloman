def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "varnishstat failed", "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "empty varnishstat output", "data": {"discovery": []}}
        data = json.decode(res.stdout)
        section = data.get("data", {})
        n_wrk_data = section.get("n_wrk")
        n_wrk_create_data = section.get("n_wrk_create")
        has_n_wrk = n_wrk_data != None and n_wrk_data.get("value") != None
        has_n_wrk_create = n_wrk_create_data != None and n_wrk_create_data.get("value") != None
        if has_n_wrk and has_n_wrk_create:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {"levels_lower": [70.0, 60.0]},
                            "metrics": ["varnish_worker_thread_ratio"]
                        }
                    ]
                },
            }
        return {"changed": False, "msg": "discovered 0 services", "data": {"discovery": []}}

    res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "varnishstat failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "empty varnishstat output", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    section = data.get("data", {})
    n_wrk_data = section.get("n_wrk")
    n_wrk_create_data = section.get("n_wrk_create")
    if n_wrk_data == None or n_wrk_create_data == None:
        return {"changed": False, "msg": "missing required metrics n_wrk or n_wrk_create", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    n_wrk = n_wrk_data.get("value")
    n_wrk_create = n_wrk_create_data.get("value")
    if n_wrk == None or n_wrk_create == None:
        return {"changed": False, "msg": "missing required values", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if n_wrk_create <= 0:
        return {"changed": False, "msg": "worker creation count is zero", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    ratio = 100.0 * n_wrk / n_wrk_create
    levels = params.get("levels_lower", [70.0, 60.0])
    warn = levels[0]
    crit = levels[1]
    state = "OK"
    if ratio <= crit:
        state = "CRIT"
    elif ratio <= warn:
        state = "WARN"
    return {
        "changed": False,
        "msg": "Ratio: %f%%" % ratio,
        "data": {
            "state": state,
            "metrics": {"varnish_worker_thread_ratio": ratio},
            "details": ""
        }
    }