# No try/except — JSON parsing guarded with checks
# No is/is not — use == None / != None

def _human_rate(x):
    return "%f/s" % x

def _check_levels(value, metric_name, levels, human_func, infoname):
    if value == None:
        return None, infoname + " not available"
    warn = None
    crit = None
    if levels != None and type(levels) == "dict":
        warn = levels.get("upper")
        crit = levels.get("lower")
    # Checkmk uses upper for WARN/CRIT when levels provided; we follow the same
    if crit != None and value >= crit:
        return "CRIT", "%s: %s (warn at %s, crit at %s)" % (infoname, human_func(value), human_func(warn) if warn != None else "none", human_func(crit))
    if warn != None and value >= warn:
        return "WARN", "%s: %s (warn at %s)" % (infoname, human_func(value), human_func(warn))
    return "OK", "%s: %s" % (infoname, human_func(value))

def main(ctx, params):
    if params.get("_discover"):
        # Read the agent output directly via the same source the Checkmk agent plugin uses
        res = ctx.run(["curl", "-s", "-u", params.get("user", "Administrator"), ":" + params.get("password", ""), 
                       "http://" + params.get("host", "localhost") + ":" + str(params.get("port", 8091)) + "/pools/default/buckets"], 
                      mutates=False)
        if res.rc != 0:
            # Not found or unreachable — skip discovery
            return {"changed": False, "msg": "discovered 0 buckets", "data": {"discovery": []}}
        if res.stdout == "":
            return {"changed": False, "msg": "discovered 0 buckets", "data": {"discovery": []}}
        data = json.decode(res.stdout)
        
        out = []
        for bucket in data:
            name = bucket.get("name")
            if name == None or name == "":
                continue
            # We'll discover per-bucket; total discovery handled by the other check plugin
            out.append({"item": name, "params": {}, "metrics": ["op_s", "cmd_get", "cmd_set", "ep_ops_create", "ep_ops_update", "ep_num_ops_del_meta"]})
        # Add total bucket operations if any bucket exists
        if len(out) > 0:
            out.append({"item": "", "params": {}, "metrics": ["op_s", "cmd_get", "cmd_set", "ep_ops_create", "ep_ops_update", "ep_num_ops_del_meta"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    
    # Check mode
    item = params.get("item", "")
    # Fetch per-bucket or total stats depending on item
    endpoint = "/pools/default/buckets/" + item if item != "" else "/pools/default/buckets"
    res = ctx.run(["curl", "-s", "-u", params.get("user", "Administrator"), ":" + params.get("password", ""), 
                   "http://" + params.get("host", "localhost") + ":" + str(params.get("port", 8091)) + endpoint], 
                  mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "no data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    
    # Prepare final data structure
    if item == "":
        # Sum all buckets for total stats
        total_stats = {}
        for bucket in data:
            # Try alternate structures
            ops_data = None
            if bucket.get("stats"):
                ops_data = bucket["stats"].get("op")
                if not ops_data:
                    ops_data = bucket["stats"].get("bucket")
            if ops_data != None:
                ops = ops_data.get("ops", 0)
                cmd_get = ops_data.get("cmd_get", 0)
                cmd_set = ops_data.get("cmd_set", 0)
                creates = ops_data.get("ep_ops_create", 0)
                updates = ops_data.get("ep_ops_update", 0)
                deletes = ops_data.get("ep_num_ops_del_meta", 0)
                total_stats["ops"] = total_stats.get("ops", 0) + ops
                total_stats["cmd_get"] = total_stats.get("cmd_get", 0) + cmd_get
                total_stats["cmd_set"] = total_stats.get("cmd_set", 0) + cmd_set
                total_stats["ep_ops_create"] = total_stats.get("ep_ops_create", 0) + creates
                total_stats["ep_ops_update"] = total_stats.get("ep_ops_update", 0) + updates
                total_stats["ep_num_ops_del_meta"] = total_stats.get("ep_num_ops_del_meta", 0) + deletes
        data = total_stats
    else:
        # Per-bucket stats
        if data.get("stats"):
            ops_data = data["stats"].get("op")
            if not ops_data:
                ops_data = data["stats"].get("bucket")
            if ops_data != None:
                data = ops_data
            else:
                data = {}
        else:
            data = {}

    # Build metrics dict and details string
    metrics = {}
    details_parts = []

    # Ops (total operations per second)
    ops = data.get("ops")
    if ops != None:
        metrics["op_s"] = ops
        state, msg = _check_levels(ops, "op_s", params.get("ops"), _human_rate, "Total (per server)")
        details_parts.append(msg)

    # cmd_get
    cmd_get = data.get("cmd_get")
    if cmd_get != None:
        metrics["cmd_get"] = cmd_get
        state2, msg = _check_levels(cmd_get, None, None, _human_rate, "Gets")
        details_parts.append(msg)

    # cmd_set
    cmd_set = data.get("cmd_set")
    if cmd_set != None:
        metrics["cmd_set"] = cmd_set
        state2, msg = _check_levels(cmd_set, None, None, _human_rate, "Sets")
        details_parts.append(msg)

    # ep_ops_create
    creates = data.get("ep_ops_create")
    if creates != None:
        metrics["ep_ops_create"] = creates
        state2, msg = _check_levels(creates, None, None, _human_rate, "Creates")
        details_parts.append(msg)

    # ep_ops_update
    updates = data.get("ep_ops_update")
    if updates != None:
        metrics["ep_ops_update"] = updates
        state2, msg = _check_levels(updates, None, None, _human_rate, "Updates")
        details_parts.append(msg)

    # ep_num_ops_del_meta
    deletes = data.get("ep_num_ops_del_meta")
    if deletes != None:
        metrics["ep_num_ops_del_meta"] = deletes
        state2, msg = _check_levels(deletes, None, None, _human_rate, "Deletes")
        details_parts.append(msg)

    # Determine final state — CRIT > WARN > OK
    final_state = "OK"
    for part in details_parts:
        if part.startswith("CRIT"):
            final_state = "CRIT"
        elif part.startswith("WARN") and final_state != "CRIT":
            final_state = "WARN"

    msg = "; ".join(details_parts) if details_parts else "no metrics"
    return {"changed": False, "msg": msg, "data": {"state": final_state, "metrics": metrics, "details": ""}}