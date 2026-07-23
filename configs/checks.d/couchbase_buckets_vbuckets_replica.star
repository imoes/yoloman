def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["curl", "-s", "-u", params.get("username", "Administrator"), 
                      params.get("url", "http://localhost:8091/pools/default/buckets")],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to fetch buckets: " + res.stderr,
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "empty response from API",
                    "data": {"discovery": []}}
        buckets = json.decode(res.stdout)
        items = []
        for b in buckets:
            name = b.get("name", "")
            if not name:
                continue
            stats_res = ctx.run(["curl", "-s", "-u", params.get("username", "Administrator"),
                                params.get("url", "http://localhost:8091/pools/default/buckets") + "/" + name + "/stats"],
                                mutates=False)
            if stats_res.rc == 0 and stats_res.stdout:
                stats = json.decode(stats_res.stdout) if stats_res.stdout else {}
                has_replica = False
                if "op" in stats:
                    bucket_stats = stats["op"]
                    for key, val in bucket_stats.items():
                        if isinstance(val, dict) and "vb_replica_num" in val:
                            has_replica = True
                            break
                if has_replica:
                    items.append({"item": name, "params": {}, "metrics": ["vbuckets", "item_memory"]})
        return {"changed": False, "msg": "discovered %d buckets with replica vBuckets" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no bucket name provided",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    details_res = ctx.run(["curl", "-s", "-u", params.get("username", "Administrator"),
                          params.get("url", "http://localhost:8091/pools/default/buckets") + "/" + item],
                          mutates=False)
    if details_res.rc != 0 or not details_res.stdout:
        return {"changed": False, "msg": "bucket not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    stats_res = ctx.run(["curl", "-s", "-u", params.get("username", "Administrator"),
                        params.get("url", "http://localhost:8091/pools/default/buckets") + "/" + item + "/stats"],
                        mutates=False)
    if stats_res.rc != 0 or not stats_res.stdout:
        return {"changed": False, "msg": "failed to fetch stats for bucket: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    stats = json.decode(stats_res.stdout) if stats_res.stdout else {}
    if "op" not in stats:
        return {"changed": False, "msg": "no stats data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    bucket_stats = stats["op"]
    
    replica_num = None
    item_memory = None
    
    for key, val in bucket_stats.items():
        if isinstance(val, dict):
            if "vb_replica_num" in val:
                num_str = val["vb_replica_num"]
                replica_num = int(num_str) if str(num_str).isdigit() else None
            if "vb_replica_itm_memory" in val:
                mem_str = val["vb_replica_itm_memory"]
                item_memory = int(mem_str) if str(mem_str).isdigit() else None
    
    state = "OK"
    details_parts = []
    
    if replica_num != None:
        warn_replica = params.get("vb_replica_num", (None, None))
        crit_replica = (None, None)
        if len(warn_replica) == 4:
            crit_replica = (warn_replica[2], warn_replica[3])
            warn_replica = (warn_replica[0], warn_replica[1])
        
        if len(warn_replica) >= 4:
            lower_warn, lower_crit, upper_warn, upper_crit = warn_replica
            if (lower_crit != None and replica_num <= lower_crit) or (upper_crit != None and replica_num >= upper_crit):
                state = "CRIT"
            elif (lower_warn != None and replica_num <= lower_warn) or (upper_warn != None and replica_num >= upper_warn):
                state = "WARN" if state != "CRIT" else state
        else:
            if replica_num == 0:
                state = "CRIT"
        
        details_parts.append("Total number: %d" % replica_num)
    
    if item_memory != None:
        mem_levels = params.get("item_memory", (None, None, None, None))
        if len(mem_levels) >= 4:
            lower_warn, lower_crit, upper_warn, upper_crit = mem_levels
            if upper_crit != None and item_memory >= upper_crit:
                state = "CRIT"
            elif upper_warn != None and item_memory >= upper_warn:
                state = "WARN" if state != "CRIT" else state
        
        b = item_memory
        formatted = False
        for unit in ["B", "KB", "MB", "GB", "TB"]:
            if abs(b) < 1024.0:
                details_parts.append("Item memory: %d %s" % (b, unit))
                formatted = True
                break
            b = b / 1024.0
        if not formatted:
            details_parts.append("Item memory: %d PB" % b)
    
    msg = "bucket '%s': " % item + ", ".join(details_parts) if details_parts else "bucket '%s': no replica data" % item
    
    metrics = {}
    if replica_num != None:
        metrics["vbuckets"] = replica_num
    if item_memory != None:
        metrics["item_memory"] = item_memory
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }