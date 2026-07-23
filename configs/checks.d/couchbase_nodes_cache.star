def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["/usr/bin/curl", "-s", "-u", params.get("user", "admin"), 
                       params.get("password", ""), "-X", "GET", 
                       params.get("url", "http://localhost:8091/pools/default/buckets/default/nodes")], 
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to fetch node data", 
                    "data": {"discovery": []}}
        if res.stdout == "":
            return {"changed": False, "msg": "empty response from server", 
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        nodes = data.get("nodes", [])
        out = []
        for node in nodes:
            node_data = node.get("statistics", {})
            if "get_hits" in node_data and "ep_bg_fetched" in node_data:
                item = node.get("hostname", "").split(":")[0]
                if item == "":
                    node_field = node.get("node", "")
                    if "@" in node_field:
                        item = node_field.split("@")[1]
                    else:
                        item = ""
                if item != "":
                    out.append({"item": item, "params": {}, "metrics": ["cache_misses_rate", "cache_hit_ratio"]})
        return {"changed": False, "msg": "discovered %d nodes" % len(out), 
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run(["/usr/bin/curl", "-s", "-u", params.get("user", "admin"), 
                   params.get("password", ""), "-X", "GET", 
                   params.get("url", "http://localhost:8091/pools/default/buckets/default/nodes")], 
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to fetch node data", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.stdout == "":
        return {"changed": False, "msg": "empty response from server", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    
    nodes = data.get("nodes", [])
    node_data = None
    for node in nodes:
        node_name = node.get("hostname", "").split(":")[0]
        if node_name == "":
            node_field = node.get("node", "")
            if "@" in node_field:
                node_name = node_field.split("@")[1]
            else:
                node_name = ""
        if node_name == item:
            node_data = node.get("statistics", {})
            break
    
    if node_data == None:
        return {"changed": False, "msg": "node not found: " + item, 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    misses = node_data.get("ep_bg_fetched")
    hits = node_data.get("get_hits")
    if misses == None or hits == None:
        return {"changed": False, "msg": "missing cache statistics", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    total = misses + hits
    hit_perc = (float(hits) / float(total)) * 100.0 if total != 0 else 100.0
    miss_rate = float(misses)
    
    cache_misses = params.get("cache_misses", (None, None))
    cache_hits = params.get("cache_hits", (None, None))
    
    state = "OK"
    if cache_misses[1] != None and miss_rate >= cache_misses[1]:
        state = "CRIT"
    elif cache_misses[0] != None and miss_rate >= cache_misses[0]:
        state = "WARN"
    
    if cache_hits[0] != None and hit_perc <= cache_hits[0]:
        state = "CRIT"
    elif cache_hits[1] != None and hit_perc <= cache_hits[1]:
        state = "WARN"
    
    return {"changed": False, "msg": "Cache hits: %d%%, Cache misses: %f/s" % (hit_perc, miss_rate),
            "data": {"state": state, 
                     "metrics": {"cache_misses_rate": miss_rate, "cache_hit_ratio": hit_perc}, 
                     "details": ""}}
