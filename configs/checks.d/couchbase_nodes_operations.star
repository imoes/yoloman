def main(ctx, params):
    if params.get("_discover"):
        return discover(ctx, params)
    return check(ctx, params)

def discover(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", "8091")
    user = params.get("user", "")
    password = params.get("password", "")
    res = ctx.run(["curl", "-s", "-u", user + ":" + password, "http://" + host + ":" + port + "/pools/default/buckets/default/stats"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no couchbase reachable", "data": {"discovery": []}}
    if not res.stdout:
        return {"changed": False, "msg": "no couchbase stats", "data": {"discovery": []}}
    data = json.decode(res.stdout)
    nodes = data.get("nodes", [])
    items = []
    for node in nodes:
        name = node.get("name", "")
        if name == "":
            name = node.get("hostname", "")
        if name == "":
            continue
        items.append({"item": name, "params": {"ops": (0, 0)}, "metrics": ["op_s"]})
    return {"changed": False, "msg": "discovered %d items" % len(items), "data": {"discovery": items}}

def check(ctx, params):
    item = params.get("item", "")
    host = params.get("host", "localhost")
    port = params.get("port", "8091")
    user = params.get("user", "")
    password = params.get("password", "")
    res = ctx.run(["curl", "-s", "-u", user + ":" + password, "http://" + host + ":" + port + "/pools/default/buckets/default/stats"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no couchbase reachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    nodes = data.get("nodes", [])
    value = None
    for node in nodes:
        name = node.get("name", "")
        if name == "":
            name = node.get("hostname", "")
        if name == item:
            stats = node.get("ops", {})
            samples = stats.get("samples", [])
            if len(samples) > 0:
                last = samples[len(samples) - 1]
                if last != None:
                    value = float(last)
                else:
                    value = 0.0
            break
    if value == None:
        return {"changed": False, "msg": "no data for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("ops", (0, 0))
    if type(levels) == "list" or type(levels) == "tuple":
        if len(levels) >= 2:
            w = levels[0]
            c = levels[1]
        elif len(levels) == 1:
            w = levels[0]
            c = levels[0]
        else:
            w = 0
            c = 0
    else:
        w = 0
        c = 0
    state = "OK"
    if c > 0 and value >= c:
        state = "CRIT"
    elif w > 0 and value >= w:
        state = "WARN"
    return {"changed": False, "msg": "%s %f/s" % (item, value), "data": {"state": state, "metrics": {"op_s": value}, "details": ""}}