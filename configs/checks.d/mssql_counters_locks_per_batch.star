def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/mssql-agent/mssql_counters.json"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read mssql_counters.json", "data": {"discovery": []}}
        
        if not res.stdout:
            return {"changed": False, "msg": "empty JSON in mssql_counters.json", "data": {"discovery": []}}
        
        section = json.decode(res.stdout)
        
        db_names = []
        for obj_instance, counters in section.items():
            obj = obj_instance[0]
            if ":" in obj:
                db_name = obj.split(":")[0]
                db_names.append(db_name)
        
        seen = {}
        for db_name in db_names:
            locks_key = (db_name + ":Locks", "_Total")
            stats_key = (db_name + ":SQL_Statistics", "None")
            if locks_key in section and stats_key in section:
                locks_counters = section.get(locks_key, {})
                stats_counters = section.get(stats_key, {})
                if "lock_requests/sec" in locks_counters and "batch_requests/sec" in stats_counters:
                    seen[db_name] = True
        
        items = list(seen.keys())
        discovery = []
        for db in items:
            discovery.append({"item": db, "params": {"locks_per_batch": (10.0, 20.0)}, "metrics": ["locks_per_batch"]})
        
        return {"changed": False, "msg": "discovered %d databases" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/mssql-agent/mssql_counters.json"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read mssql_counters.json", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if not res.stdout:
        return {"changed": False, "msg": "empty JSON in mssql_counters.json", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = json.decode(res.stdout)
    
    locks_key = (item + ":Locks", "_Total")
    stats_key = (item + ":SQL_Statistics", "None")
    data_locks = section.get(locks_key, {})
    data_stats = section.get(stats_key, {})
    
    if not data_locks and not data_stats:
        return {"changed": False, "msg": "Item not found in monitoring data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lock_rate_base = data_locks.get("lock_requests/sec")
    batch_rate_base = data_stats.get("batch_requests/sec")
    
    if lock_rate_base == None or batch_rate_base == None:
        return {"changed": False, "msg": "Required counters missing", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lock_rate = float(lock_rate_base)
    batch_rate = float(batch_rate_base)
    
    levels = params.get("locks_per_batch", (10.0, 20.0))
    warn, crit = levels if isinstance(levels, tuple) else (levels, levels)
    
    locks_per_batch = lock_rate / batch_rate if batch_rate else 0
    
    state = "OK"
    if locks_per_batch >= crit:
        state = "CRIT"
    elif locks_per_batch >= warn:
        state = "WARN"
    
    msg = "[%s] Locks per batch: %f" % (item, locks_per_batch)
    
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"locks_per_batch": locks_per_batch}, "details": ""}}