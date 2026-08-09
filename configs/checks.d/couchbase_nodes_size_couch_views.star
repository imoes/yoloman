def _levels_upper(levels):
    if levels == None:
        return None
    return ("fixed", levels)

def _check_levels(value, levels, metric_name, render_func_label, state, metrics, details_list):
    if levels != None:
        warn = levels[0]
        crit = levels[1]
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
    metrics[metric_name] = value
    details_list.append("%s: %d" % (render_func_label, value))
    return state

def _make_check(key_disk, key_size):
    def _check(item, params, section, metrics, details_list):
        state = "OK"
        data = section.get(item)
        if data == None:
            return None
        on_disk = data.get(key_disk)
        if on_disk != None:
            levels_disk = params.get("size_on_disk")
            state = _check_levels(on_disk, levels_disk, "size_on_disk", "Size on disk", state, metrics, details_list)
        size = data.get(key_size)
        if size != None:
            levels_size = params.get("size")
            state = _check_levels(size, levels_size, "data_size", "Data size", state, metrics, details_list)
        return state
    return _check

def _run_couchbase_api(ctx, host, port, username, password, path):
    cmd = ["curl", "-s", "-u", "%s:%s" % (username, password), "http://%s:%s%s" % (host, port, path)]
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return None
    if not res.stdout:
        return None
    data = json.decode(res.stdout)
    return data

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", "8091")
    username = params.get("username", "")
    password = params.get("password", "")
    if params.get("_discover"):
        probe = _run_couchbase_api(ctx, host, port, username, password, "/pools/default")
        if probe == None:
            return {"changed": False, "msg": "Couchbase node not reachable",
                    "data": {"discovery": [], "details": "Couchbase API at %s:%s not reachable" % (host, port)}}
        nodes_res = _run_couchbase_api(ctx, host, port, username, password, "/pools/default/buckets")
        if nodes_res == None:
            return {"changed": False, "msg": "Couchbase buckets not reachable",
                    "data": {"discovery": [], "details": "Could not retrieve Couchbase buckets"}}
        discovery = []
        for bucket in nodes_res:
            bucket_name = bucket.get("name", "")
            vbucket_server = bucket.get("vBucketServerMap", {})
            if vbucket_server == None:
                continue
            server_nodes = vbucket_server.get("serverList", [])
            seen = {}
            for node in server_nodes:
                node_hostname = node.get("hostname", "")
                if node_hostname == "":
                    continue
                if node_hostname not in seen:
                    seen[node_hostname] = True
                    discovery.append({
                        "item": node_hostname,
                        "params": {"size_on_disk": params.get("size_on_disk"),
                                   "size": params.get("size")},
                        "metrics": ["size_on_disk", "data_size"]
                    })
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery, "details": "Couchbase Couch Views services"}}
    item = params.get("item", "")
    check_fn = _make_check("couch_views_actual_disk_size", "couch_views_data_size")
    stats = _run_couchbase_api(ctx, host, port, username, password, "/nodes/self/stats")
    if stats == None:
        return {"changed": False, "msg": "Couchbase node not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Could not retrieve Couchbase node stats"}}
    section = {}
    section[item] = stats
    metrics = {}
    details_list = []
    state = check_fn(item, params, section, metrics, details_list)
    if state == None:
        return {"changed": False, "msg": "Couchbase node not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Node not found in section"}}
    details_str = "; ".join(details_list)
    return {"changed": False, "msg": details_str if details_str else "Couchbase Couch Views checked",
            "data": {"state": state, "metrics": metrics, "details": details_str}}