def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "varnishstat command failed", "data": {"discovery": []}}
        
        if not res.stdout:
            return {"changed": False, "msg": "no output from varnishstat", "data": {"discovery": []}}
        
        data = json.decode(res.stdout)
        section = data.get("varnishstat", {})
        if type(section) != "dict":
            return {"changed": False, "msg": "malformed varnishstat JSON", "data": {"discovery": []}}
        
        keys = set()
        klist = section.keys()
        i = 0
        while i < len(klist):
            k = klist[i]
            if str(k).find(".") == -1:
                keys.add(k)
            i = i + 1
        
        required = ["backend_busy", "backend_unhealthy", "backend_fail"]
        found_all = True
        j = 0
        while j < len(required):
            if not required[j] in keys:
                found_all = False
                break
            j = j + 1
        
        if found_all:
            return {
                "changed": False,
                "msg": "discovered Varnish Backend service",
                "data": {
                    "discovery": [{
                        "item": "",
                        "params": {},
                        "metrics": [
                            "varnish_backend_busy_rate",
                            "varnish_backend_unhealthy_rate",
                            "varnish_backend_req_rate",
                            "varnish_backend_recycle_rate",
                            "varnish_backend_retry_rate",
                            "varnish_backend_fail_rate",
                            "varnish_backend_toolate_rate",
                            "varnish_backend_conn_rate",
                            "varnish_backend_reuse_rate"
                        ]
                    }]
                },
            }
        else:
            return {"changed": False, "msg": "no backend metrics found", "data": {"discovery": []}}
    
    res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "varnishstat command failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if not res.stdout:
        return {
            "changed": False,
            "msg": "no output from varnishstat",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    data = json.decode(res.stdout)
    section = data.get("varnishstat", {})
    if type(section) != "dict":
        return {
            "changed": False,
            "msg": "malformed varnishstat JSON",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    required = ["backend_busy", "backend_unhealthy", "backend_fail"]
    i = 0
    while i < len(required):
        key = required[i]
        if not section.get(key):
            return {
                "changed": False,
                "msg": "missing backend metric %s" % key,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        i = i + 1
    
    metrics = {}
    key_to_metric = {
        "backend_busy": "varnish_backend_busy_rate",
        "backend_unhealthy": "varnish_backend_unhealthy_rate",
        "backend_req": "varnish_backend_req_rate",
        "backend_recycle": "varnish_backend_recycle_rate",
        "backend_retry": "varnish_backend_retry_rate",
        "backend_fail": "varnish_backend_fail_rate",
        "backend_toolate": "varnish_backend_toolate_rate",
        "backend_conn": "varnish_backend_conn_rate",
        "backend_reuse": "varnish_backend_reuse_rate"
    }
    
    i = 0
    klist = key_to_metric.keys()
    while i < len(klist):
        varnish_key = klist[i]
        entry = section.get(varnish_key)
        if entry:
            val = entry.get("value")
            if val != None and type(val) == "int":
                metrics[key_to_metric[varnish_key]] = val
        i = i + 1
    
    state = "OK"
    msg_parts = []
    i = 0
    while i < len(required):
        key = required[i]
        entry = section.get(key)
        if entry:
            val = entry.get("value")
            if val == None:
                val = 0
            msg_parts.append("%s=%d" % (key, val))
        i = i + 1
    
    return {
        "changed": False,
        "msg": "Varnish Backend: " + ", ".join(msg_parts) if len(msg_parts) > 0 else "Varnish Backend: no data",
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
