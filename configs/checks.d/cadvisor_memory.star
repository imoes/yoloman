def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/yolo-man/agent/cadvisor_memory"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        memory_info = json.decode(res.stdout) if res.stdout.strip() else None
        if memory_info == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        if memory_info:
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": ["mem_used", "mem_lnx_cached", "swap_used"]}]}}
        else:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
    
    # Check mode - get data and compute result
    res = ctx.run(["cat", "/var/lib/yolo-man/agent/cadvisor_memory"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    memory_info = json.decode(res.stdout)
    if memory_info == None:
        return {"changed": False, "msg": "could not parse JSON data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Check required fields exist
    required_fields = ["memory_usage_pod", "memory_machine"]
    has_required = True
    for field in required_fields:
        if not (field in memory_info):
            has_required = False
            break
    
    if not has_required:
        return {"changed": False, "msg": "missing required memory fields",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Checking for Container
    if "memory_usage_container" in memory_info:
        memory_used = float(memory_info["memory_usage_container"][0]["value"])
        memory_total = float(memory_info["memory_usage_pod"][0]["value"])
        infotext_extra = " (Parent pod memory usage)"
    else:
        memory_used = float(memory_info["memory_usage_pod"][0]["value"])
        memory_total = float(memory_info["memory_machine"][0]["value"])
        infotext_extra = " (Available Machine Memory)"
        if "memory_limit" in memory_info and float(memory_info["memory_limit"][0]["value"]) > 0:
            memory_total = float(memory_info["memory_limit"][0]["value"])
            infotext_extra = ""
    
    # Build summary text
    usage_percent = (100.0 * memory_used / memory_total) if memory_total > 0 else 0.0
    summary = "Usage: %f%% - %f of %f%s" % (
        usage_percent, 
        memory_used / 1024, 
        memory_total / 1024, 
        infotext_extra
    )
    
    # Build metrics
    metrics = {
        "mem_used": memory_used,
    }
    
    # Add additional metrics if available
    if "memory_rss" in memory_info and len(memory_info["memory_rss"]) == 1:
        rss = float(memory_info["memory_rss"][0]["value"])
        summary += " (RSS: %f kB)" % (rss / 1024)
    
    if "memory_cache" in memory_info and len(memory_info["memory_cache"]) == 1:
        cache = float(memory_info["memory_cache"][0]["value"])
        metrics["mem_lnx_cached"] = cache
        summary += " (Cache: %f kB)" % (cache / 1024)
    
    if "memory_swap" in memory_info and len(memory_info["memory_swap"]) == 1:
        swap = float(memory_info["memory_swap"][0]["value"])
        metrics["swap_used"] = swap
        summary += " (Swap: %f kB)" % (swap / 1024)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": "",
        },
    }