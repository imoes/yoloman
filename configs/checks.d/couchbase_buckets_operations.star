def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _discover(ctx, params):
    res = ctx.run([
        "curl", "-s", "-u", params.get("user", "admin") + ":" + params.get("password", ""),
        params.get("url", "http://localhost:8091/pools/default/buckets")
    ], mutates=False)
    if res.rc != 0:
        # Agent not available -> no items to discover
        return {"changed": False, "msg": "no buckets discovered", "data": {"discovery": []}}

    if not res.stdout:
        return {"changed": False, "msg": "no buckets discovered", "data": {"discovery": []}}
    buckets = json.decode(res.stdout)
    if type(buckets) != "list":
        return {"changed": False, "msg": "no buckets discovered", "data": {"discovery": []}}

    items = []
    for bucket in buckets:
        name = bucket.get("name")
        if type(name) == "string" and name != "":
            items.append({
                "item": name,
                "params": {},
                "metrics": ["op_s", "gets", "sets", "creates", "updates", "deletes"]
            })
    # Also expose a total service for sum of all buckets
    items.append({
        "item": "",
        "params": {},
        "metrics": ["op_s", "gets", "sets", "creates", "updates", "deletes"]
    })
    return {"changed": False, "msg": "discovered %d buckets" % len(items),
            "data": {"discovery": items}}


def _check(ctx, params):
    item = params.get("item", "")
    if item == "":
        url = params.get("url", "http://localhost:8091/pools/default/buckets")
    else:
        url = params.get("url", "http://localhost:8091/pools/default/buckets/" + item)

    res = ctx.run([
        "curl", "-s", "-u", params.get("user", "admin") + ":" + params.get("password", ""),
        url
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "bucket data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if not res.stdout:
        return {
            "changed": False,
            "msg": "bucket data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    data = None
    if item == "":
        buckets = json.decode(res.stdout)
        if type(buckets) == "list":
            # Sum all buckets' ops fields
            total = {"ops": 0, "cmd_get": 0, "cmd_set": 0,
                     "ep_ops_create": 0, "ep_ops_update": 0, "ep_num_ops_del_meta": 0}
            for b in buckets:
                stat = b.get("stats", {})
                total["ops"] += stat.get("ops", 0) if type(stat.get("ops", 0)) == "int" else 0
                total["cmd_get"] += stat.get("cmd_get", 0) if type(stat.get("cmd_get", 0)) == "int" else 0
                total["cmd_set"] += stat.get("cmd_set", 0) if type(stat.get("cmd_set", 0)) == "int" else 0
                total["ep_ops_create"] += stat.get("ep_ops_create", 0) if type(stat.get("ep_ops_create", 0)) == "int" else 0
                total["ep_ops_update"] += stat.get("ep_ops_update", 0) if type(stat.get("ep_ops_update", 0)) == "int" else 0
                total["ep_num_ops_del_meta"] += stat.get("ep_num_ops_del_meta", 0) if type(stat.get("ep_num_ops_del_meta", 0)) == "int" else 0
            data = total
    else:
        single_data = json.decode(res.stdout)
        if type(single_data) == "dict":
            stat = single_data.get("stats", {})
            data = {
                "ops": stat.get("ops", 0) if type(stat.get("ops", 0)) == "int" else 0,
                "cmd_get": stat.get("cmd_get", 0) if type(stat.get("cmd_get", 0)) == "int" else 0,
                "cmd_set": stat.get("cmd_set", 0) if type(stat.get("cmd_set", 0)) == "int" else 0,
                "ep_ops_create": stat.get("ep_ops_create", 0) if type(stat.get("ep_ops_create", 0)) == "int" else 0,
                "ep_ops_update": stat.get("ep_ops_update", 0) if type(stat.get("ep_ops_update", 0)) == "int" else 0,
                "ep_num_ops_del_meta": stat.get("ep_num_ops_del_meta", 0) if type(stat.get("ep_num_ops_del_meta", 0)) == "int" else 0
            }

    if data == None:
        return {
            "changed": False,
            "msg": "bucket data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Thresholds: use Checkmk defaults (no levels by default -> OK)
    ops_warn = None
    ops_crit = None
    ops_levels = params.get("ops_levels")
    if ops_levels != None:
        ops_warn = ops_levels.get("ops_warn")
        ops_crit = ops_levels.get("ops_crit")

    # Apply thresholds (Checkmk style: upper levels warn/crit)
    state = "OK"
    metrics = {}
    msg_parts = []

    # Total ops (per server)
    if data.get("ops") != None:
        ops_val = float(data.get("ops"))
        metrics["op_s"] = ops_val
        msg_parts.append("Total (per server): %f/s" % ops_val)
        if ops_crit != None and ops_val >= ops_crit:
            state = "CRIT"
        elif ops_warn != None and ops_val >= ops_warn:
            state = "WARN"

    # Gets
    if data.get("cmd_get") != None:
        gets_val = float(data.get("cmd_get"))
        metrics["gets"] = gets_val
        msg_parts.append("Gets: %f/s" % gets_val)

    # Sets
    if data.get("cmd_set") != None:
        sets_val = float(data.get("cmd_set"))
        metrics["sets"] = sets_val
        msg_parts.append("Sets: %f/s" % sets_val)

    # Creates
    if data.get("ep_ops_create") != None:
        creates_val = float(data.get("ep_ops_create"))
        metrics["creates"] = creates_val
        msg_parts.append("Creates: %f/s" % creates_val)

    # Updates
    if data.get("ep_ops_update") != None:
        updates_val = float(data.get("ep_ops_update"))
        metrics["updates"] = updates_val
        msg_parts.append("Updates: %f/s" % updates_val)

    # Deletes
    if data.get("ep_num_ops_del_meta") != None:
        deletes_val = float(data.get("ep_num_ops_del_meta"))
        metrics["deletes"] = deletes_val
        msg_parts.append("Deletes: %f/s" % deletes_val)

    msg = "; ".join(msg_parts) if msg_parts else "no ops data"
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }