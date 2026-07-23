MIB = 1048576.0

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["ceph", "df", "detail", "--format", "json"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "failed to get ceph df data", 
                    "data": {"discovery": []}}
        
        if not res.stdout.strip():
            return {"changed": False, "msg": "empty ceph df output", 
                    "data": {"discovery": []}}
        
        data = json.decode(res.stdout)
        
        pools = data.get("pools", [])
        classes = data.get("stats_by_class", {})
        
        discovery_items = []
        for pool in pools:
            pool_name = pool.get("name", "")
            if pool_name:
                discovery_items.append({
                    "item": pool_name,
                    "params": {"levels": (80.0, 90.0)},
                    "metrics": ["size_bytes", "avail_bytes", "objects", "disk_read_ios", 
                               "disk_write_ios", "disk_read_throughput", "disk_write_throughput"]
                })
        
        for class_name in classes:
            discovery_items.append({
                "item": class_name,
                "params": {"levels": (80.0, 90.0)},
                "metrics": ["size_bytes", "avail_bytes"]
            })
        
        return {"changed": False, "msg": "discovered %d items" % len(discovery_items),
                "data": {"discovery": discovery_items}}
    
    item = params.get("item", "")
    res = ctx.run(["ceph", "df", "detail", "--format", "json"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "failed to get ceph df data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)
    
    pools = {p.get("name", ""): p for p in data.get("pools", [])}
    classes = data.get("stats_by_class", {})
    
    if item in pools:
        pool = pools[item]
        stats = pool.get("stats", {})
        
        used_mb = 0.0
        avail_mb = 0.0
        size_mb = 0.0
        
        if "stored" in stats:
            used_mb = stats.get("stored", 0) / MIB
            max_avail = stats.get("max_avail")
            if max_avail != None and max_avail > 0:
                avail_mb = max_avail / MIB
                size_mb = used_mb + avail_mb
            elif "percent_used" in stats and stats["percent_used"] > 0:
                size_mb = used_mb / (stats["percent_used"] / 100.0)
                avail_mb = size_mb - used_mb
        else:
            used_mb = stats.get("bytes_used", 0) / MIB
            if "percent_used" in stats and stats["percent_used"] > 0:
                size_mb = used_mb / (stats["percent_used"] / 100.0)
                avail_mb = size_mb - used_mb
        
        levels = params.get("levels", (80.0, 90.0))
        if type(levels) == "list" or type(levels) == "tuple":
            warn = levels[0] if len(levels) >= 2 else 80.0
            crit = levels[1] if len(levels) >= 2 else 90.0
        else:
            warn = levels
            crit = levels + 10
        
        used_percent = (used_mb / size_mb * 100.0) if size_mb > 0 else 0.0
        state = "CRIT" if used_percent >= crit else ("WARN" if used_percent >= warn else "OK")
        
        metrics = {
            "size_bytes": size_mb * MIB,
            "avail_bytes": avail_mb * MIB,
            "objects": stats.get("objects", 0),
            "disk_read_ios": stats.get("rd", 0),
            "disk_write_ios": stats.get("wr", 0),
            "disk_read_throughput": stats.get("rd_bytes", 0),
            "disk_write_throughput": stats.get("wr_bytes", 0),
        }
        
        msg = "Ceph Pool %s: %f%% used (%f MB / %f MB)" % (item, used_percent, used_mb, size_mb)
        
        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": metrics, "details": ""}}
    
    elif item in classes:
        stats = classes[item]
        avail_mb = stats.get("total_avail_bytes", 0) / MIB
        size_mb = stats.get("total_bytes", 0) / MIB
        
        levels = params.get("levels", (80.0, 90.0))
        if type(levels) == "list" or type(levels) == "tuple":
            warn = levels[0] if len(levels) >= 2 else 80.0
            crit = levels[1] if len(levels) >= 2 else 90.0
        else:
            warn = levels
            crit = levels + 10
        
        used_percent = (size_mb - avail_mb) / size_mb * 100.0 if size_mb > 0 else 0.0
        state = "CRIT" if used_percent >= crit else ("WARN" if used_percent >= warn else "OK")
        
        metrics = {
            "size_bytes": size_mb * MIB,
            "avail_bytes": avail_mb * MIB,
        }
        
        msg = "Ceph Class %s: %f%% used (%f MB / %f MB)" % (item, used_percent, size_mb - avail_mb, size_mb)
        
        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": metrics, "details": ""}}
    
    else:
        return {"changed": False, "msg": "unknown pool or class: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
