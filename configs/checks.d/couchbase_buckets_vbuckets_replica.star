def main(ctx, params):
    # Probe for Couchbase on the host
    if params.get("_discover"):
        res = ctx.run(["curl", "-s", "http://localhost:8091/pools/default/buckets"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "couchbase not reachable", "data": {"discovery": []}}
        buckets = json.decode(res.stdout)
        if type(buckets) != "list":
            return {"changed": False, "msg": "unexpected couchbase response", "data": {"discovery": []}}
        out = []
        for b in buckets:
            name = b.get("name")
            basic = b.get("basic_stats", {})
            ratio = basic.get("vb_active_resident_items_ratio")
            if ratio == None:
                ratio = b.get("vb_active_resident_items_ratio")
            if ratio != None:
                out.append({"item": name, "params": {}, "metrics": ["resident_items_ratio", "item_memory", "vbuckets"]})
        return {"changed": False, "msg": "discovered %d buckets" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["curl", "-s", "http://localhost:8091/pools/default/buckets/" + item], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no bucket named " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    b = json.decode(res.stdout)
    if type(b) != "dict":
        return {"changed": False, "msg": "unexpected bucket data for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    state = "OK"
    parts = []

    replica_num_str = b.get("vb_replica_num")
    if replica_num_str != None:
        replica_num = int(replica_num_str) if str(replica_num_str).isdigit() else 0
        metrics["vbuckets"] = replica_num
        parts.append("Total replica vBuckets: %d" % replica_num)
        levels = params.get("vb_replica_num")
        if levels != None and len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]
            if replica_num >= crit:
                state = "CRIT"
            elif replica_num >= warn and state != "CRIT":
                state = "WARN"

    item_memory_str = b.get("vb_replica_itm_memory")
    if item_memory_str != None:
        item_memory = float(item_memory_str) if str(item_memory_str).replace(".", "", 1).isdigit() else 0.0
        metrics["item_memory"] = item_memory
        parts.append("Item memory: %s" % str(item_memory))
        levels = params.get("item_memory")
        if levels != None and len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]
            if item_memory >= crit:
                state = "CRIT"
            elif item_memory >= warn and state != "CRIT":
                state = "WARN"

    if len(parts) == 0:
        return {"changed": False, "msg": "no replica vBucket data for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "; ".join(parts), "data": {"state": state, "metrics": metrics, "details": ""}}