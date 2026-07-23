def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1"], mutates=False)
        output = res.stdout
        section = {}
        for line in output.splitlines():
            parts = line.split(None, 3)
            if len(parts) < 4:
                continue
            try_val = parts[1]
            value = int(try_val) if try_val.isdigit() else None
            if value == None:
                continue
            metric_name = parts[0].strip()
            descr = parts[3].strip() if len(parts) > 3 else ""
            section[metric_name] = {
                "value": value,
                "descr": descr,
                "perf_var_name": "varnish_" + metric_name.replace(".", "_").replace("(", "").replace(")", ""),
                "params_var_name": metric_name.rsplit("_", 1)[-1] if "_" in metric_name else metric_name,
            }
        if "backend_fail" in section and "backend_conn" in section:
            return {
                "changed": False,
                "msg": "discovered backend success ratio service",
                "data": {
                    "discovery": [
                        {"item": "", "params": {"levels_lower": (70.0, 60.0)}, "metrics": ["varnish_backend_success_ratio"]}
                    ]
                },
            }
        return {
            "changed": False,
            "msg": "no backend success ratio data found",
            "data": {"discovery": []}
        }
    
    item = params.get("item", "")
    res = ctx.run(["varnishstat", "-1"], mutates=False)
    output = res.stdout
    section = {}
    for line in output.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try_val = parts[1]
        value = int(try_val) if try_val.isdigit() else None
        if value == None:
            continue
        metric_name = parts[0].strip()
        section[metric_name] = {
            "value": value,
            "descr": parts[3].strip() if len(parts) > 3 else "",
        }
    
    if "backend_fail" not in section or "backend_conn" not in section:
        return {
            "changed": False,
            "msg": "backend stats missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    backend_conn = section["backend_conn"]["value"]
    backend_fail = section["backend_fail"]["value"]
    total = backend_conn + backend_fail
    ratio = 0.0
    if total > 0:
        ratio = 100.0 * backend_conn / total
    
    warn, crit = params.get("levels_lower", (70.0, 60.0))
    
    state = "CRIT" if ratio <= crit else ("WARN" if ratio <= warn else "OK")
    
    msg = "Backend success ratio: %f%%" % ratio
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"varnish_backend_success_ratio": ratio},
            "details": ""
        },
    }