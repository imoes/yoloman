def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/driver/sansymphony_serverstatus"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        lines = res.stdout.strip().splitlines()
        if len(lines) == 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    
    # check mode
    res = ctx.run(["cat", "/proc/driver/sansymphony_serverstatus"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.strip().splitlines()
    if len(lines) == 0:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parts = lines[0].strip().split()
    if len(parts) < 2:
        return {"changed": False, "msg": "malformed data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status = parts[0]
    cachestate = parts[1]
    
    if status == "Online" and cachestate == "WritebackGlobal":
        state = "OK"
        summary = "SANsymphony is Online and its cache is in WritebackGlobal mode"
    elif status == "Online" and cachestate != "WritebackGlobal":
        state = "WARN"
        summary = "SANsymphony is Online but its cache is in %s mode" % cachestate
    else:
        state = "CRIT"
        summary = "SANsymphony is %s" % status
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}