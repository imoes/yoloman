MB = 1048576.0
KB = 1024.0

def _fmt_bytes(b):
    if b >= 1073741824.0:
        return "%f GiB" % (b / 1073741824.0)
    if b >= MB:
        return "%f MiB" % (b / MB)
    if b >= KB:
        return "%f KiB" % (b / KB)
    return "%d B" % int(b)

def _controller_url(params):
    scheme = params.get("scheme", "http")
    host = params.get("host", "localhost")
    port = params.get("port", 8090)
    return "%s://%s:%d/controller/rest" % (scheme, host, port)

def _user(params):
    username = params.get("username", "admin")
    account = params.get("account", "customer1")
    password = params.get("password", "")
    return "%s@%s:%s" % (username, account, password)

def _appdyn_get(ctx, params, path):
    url = _controller_url(params) + path + "?output=JSON"
    res = ctx.run(["curl", "-s", "-f", "-u", _user(params), url], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return None
    return json.decode(res.stdout)

def _get_node_id(nodes, node_name):
    for node in nodes:
        if node.get("name") == node_name:
            return node.get("id")
    return None

def _extract_mem(mem_list, section_name):
    for entry in mem_list:
        if entry.get("name") == section_name:
            return entry
    return None

def _apply_threshold(thresh_raw, max_b):
    if thresh_raw == None or max_b <= 0:
        return None, ""
    if type(thresh_raw) == "float":
        return float(int(max_b / 100.0 * thresh_raw)), "%f%%" % thresh_raw
    if type(thresh_raw) == "int":
        return max_b - float(thresh_raw) * MB, "%d MB free" % thresh_raw
    return None, ""

def main(ctx, params):
    application = params.get("application", "")
    if not application:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "parameter 'application' is required",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    app_path = "/applications/" + application

    if params.get("_discover"):
        nodes = _appdyn_get(ctx, params, app_path + "/nodes")
        if nodes == None:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        disc = []
        for node in nodes:
            node_name = node.get("name", "")
            node_id = node.get("id", 0)
            jvm = _appdyn_get(ctx, params, app_path + "/nodes/" + str(node_id) + "/jvm-memory-metrics")
            if jvm == None:
                continue
            for entry in jvm:
                ename = entry.get("name", "")
                if ename == "Heap Memory":
                    disc.append({
                        "item": node_name + " Heap",
                        "params": {"heap": [80.0, 90.0]},
                        "metrics": ["mem_heap", "mem_heap_committed"],
                    })
                elif ename == "Non-Heap Memory":
                    disc.append({
                        "item": node_name + " Non-Heap",
                        "params": {"nonheap": [80.0, 90.0]},
                        "metrics": ["mem_nonheap", "mem_nonheap_committed"],
                    })

        return {"changed": False,
                "msg": "discovered %d items" % len(disc),
                "data": {"discovery": disc}}

    # Check mode
    item = params.get("item", "")
    if item.endswith(" Non-Heap"):
        node_name = item[:len(item) - 9]
        mem_type = "nonheap"
        api_section = "Non-Heap Memory"
    elif item.endswith(" Heap"):
        node_name = item[:len(item) - 5]
        mem_type = "heap"
        api_section = "Heap Memory"
    else:
        return {"changed": False, "msg": "unrecognised item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    nodes = _appdyn_get(ctx, params, app_path + "/nodes")
    if nodes == None:
        return {"changed": False, "msg": "cannot reach AppDynamics controller",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    node_id = _get_node_id(nodes, node_name)
    if node_id == None:
        return {"changed": False, "msg": "node not found: " + node_name,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    jvm = _appdyn_get(ctx, params, app_path + "/nodes/" + str(node_id) + "/jvm-memory-metrics")
    if jvm == None:
        return {"changed": False, "msg": "no JVM metrics for " + node_name,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mem_data = _extract_mem(jvm, api_section)
    if mem_data == None:
        return {"changed": False, "msg": "section not found: " + api_section,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # AppDynamics REST API returns sizes in KB
    max_kb = mem_data.get("max", -1)
    used_kb = mem_data.get("currentUsage", 0)
    committed_kb = mem_data.get("commitSize", 0)

    max_b = float(max_kb) * KB if max_kb > 0 else -1.0
    used_b = float(used_kb) * KB
    committed_b = float(committed_kb) * KB

    used_pct = 100.0 * used_b / max_b if max_b > 0 else 0.0

    thresholds = params.get(mem_type, None)
    warn_raw = None
    crit_raw = None
    if (thresholds != None) and (type(thresholds) == "list") and (len(thresholds) >= 2):
        warn_raw = thresholds[0]
        crit_raw = thresholds[1]

    warn_b, warn_label = _apply_threshold(warn_raw, max_b)
    crit_b, crit_label = _apply_threshold(crit_raw, max_b)

    state = "OK"
    if (crit_b != None) and (used_b >= crit_b):
        state = "CRIT"
    elif (warn_b != None) and (used_b >= warn_b):
        state = "WARN"

    levels_suffix = ""
    if state != "OK":
        levels_suffix = " (levels at %s/%s)" % (warn_label, crit_label)

    metric_key = "mem_" + mem_type
    metrics = {metric_key: used_b, metric_key + "_committed": committed_b}

    if max_b > 0:
        summary = "Used: %s of %s (%f%%)%s, Committed: %s" % (
            _fmt_bytes(used_b), _fmt_bytes(max_b), used_pct, levels_suffix, _fmt_bytes(committed_b))
    else:
        summary = "Used: %s%s, Committed: %s" % (
            _fmt_bytes(used_b), levels_suffix, _fmt_bytes(committed_b))

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}