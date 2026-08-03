def _parse_path(raw_path):
    if "(" not in raw_path:
        return raw_path.split(".")
    head_str, middle = raw_path.split("(", 1)
    address, tail = middle.split(")", 1)
    head = head_str.strip(".").split(".")
    result = []
    for h in head[:-1]:
        result.append(h)
    result.append(head[-1] + "(" + address + ")")
    tail_parts = tail.strip(".").split(".")
    for t in tail_parts:
        result.append(t)
    return result

def _create_hierarchy(path, instance):
    if len(path) == 0:
        return instance
    head = path[0]
    tail = path[1:]
    child = instance.setdefault(head, {})
    return _create_hierarchy(tail, child)

def _parse_varnish(lines):
    parsed = {}
    for line in lines:
        if len(line) < 2:
            continue
        parsed_path = _parse_path(line[0])
        instance = _create_hierarchy(parsed_path, parsed)
        value = None
        if line[1].lstrip("-").isdigit():
            value = int(line[1])
        descr = ""
        if len(line) > 3 and line[3].lower() in line[0]:
            descr = " ".join(line[4:])
        elif len(line) > 3:
            descr = " ".join(line[3:])
        elif len(line) > 2:
            descr = line[2]
        perf_var_name = "varnish_%s_rate" % parsed_path[-1]
        if perf_var_name.startswith("varnish_n_wrk"):
            perf_var_name = perf_var_name.replace("n_wrk", "worker")
        elif perf_var_name.startswith("varnish_n_"):
            perf_var_name = perf_var_name.replace("n_", "objects_")
        params_var_name = parsed_path[-1].split("_", 1)[-1]
        instance.update({"value": value, "descr": descr.replace("/", " "), "perf_var_name": perf_var_name, "params_var_name": params_var_name})
    for key in ["MAIN", "MGT"]:
        values = parsed.pop(key, {})
        parsed.update(values)
    return parsed

def _rate(store, key, this_time, value):
    prev = store.get(key)
    if prev == None or value == None or prev[0] == None or prev[1] == None:
        store[key] = (this_time, value)
        return None
    prev_time = prev[0]
    prev_value = prev[1]
    delta_t = this_time - prev_time
    if delta_t <= 0:
        store[key] = (this_time, value)
        return None
    delta_v = value - prev_value
    if delta_v < 0:
        store[key] = (this_time, value)
        return None
    rate = float(delta_v) / float(delta_t)
    store[key] = (this_time, value)
    return rate

def _check_levels(stats, msg_prefix, params_tuple):
    if stats == None:
        return ("UNKNOWN", 0.0, msg_prefix + "No data (first sample)")
    warn = params_tuple[0] if len(params_tuple) > 0 else None
    crit = params_tuple[1] if len(params_tuple) > 1 else None
    if warn == None and crit == None:
        return ("OK", stats, msg_prefix + "%f /s" % stats)
    if crit != None and stats >= crit:
        return ("CRIT", stats, msg_prefix + "%f /s" % stats)
    if warn != None and stats >= warn:
        return ("WARN", stats, msg_prefix + "%f /s" % stats)
    return ("OK", stats, msg_prefix + "%f /s" % stats)

def _varnish_stats_keys():
    return ["n_expired", "n_lru_nuked", "n_lru_moved"]

def _varnish_objects_defaults():
    return {"n_expired": (None, None), "n_lru_nuked": (None, None), "n_lru_moved": (None, None)}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "varnishstat not available", "data": {"discovery": [], "host_labels": {}}}
        out_lines = res.stdout.splitlines()
        split_lines = []
        for line in out_lines:
            split_lines.append(line.split())
        parsed = _parse_varnish(split_lines)
        out = []
        if "n_expired" in parsed and "n_lru_nuked" in parsed:
            items = _varnish_stats_keys()
            metrics = []
            for k in items:
                if k in parsed:
                    metrics.append(parsed[k]["perf_var_name"])
            out.append({"item": "", "params": _varnish_objects_defaults(), "metrics": metrics})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out, "host_labels": {}}}
    res = ctx.run(["varnishstat", "-1"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "varnishstat not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    out_lines = res.stdout.splitlines()
    split_lines = []
    for line in out_lines:
        split_lines.append(line.split())
    parsed = _parse_varnish(split_lines)
    keys = _varnish_stats_keys()
    store = {}
    this_time = 0.0
    summary_parts = []
    metric_map = {}
    worst = "OK"
    for key in keys:
        data = parsed.get(key)
        if data == None:
            continue
        perf_var_name = data["perf_var_name"]
        params_var_name = data["params_var_name"]
        default_params = (None, None)
        params_tuple = params.get(params_var_name, default_params)
        if params_tuple == None:
            params_tuple = default_params
        stats = _rate(store, "varnish.%s" % key, this_time, data["value"])
        state, val, msg = _check_levels(stats, data["descr"] + "/s: ", params_tuple)
        if stats != None:
            metric_map[perf_var_name] = stats
        summary_parts.append(data["descr"] + ": " + msg)
        if state == "CRIT":
            worst = "CRIT"
        elif state == "WARN" and worst != "CRIT":
            worst = "WARN"
        elif state == "UNKNOWN" and worst not in ("CRIT", "WARN"):
            worst = "UNKNOWN"
    if len(summary_parts) == 0:
        return {"changed": False, "msg": "no varnish objects", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": ", ".join(summary_parts), "data": {"state": worst, "metrics": metric_map, "details": ""}}