def main(ctx, params):
    if params.get("_discover"):
        nodes = _read_nodes(ctx)
        if not nodes:
            return {"changed": False, "msg": "couchbase not running", "data": {"discovery": []}}
        discovery = []
        for name in sorted(nodes.keys()):
            discovery.append({"item": name, "params": {}, "metrics": ["cpu_util"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    nodes = _read_nodes(ctx)
    if not nodes:
        return {"changed": False, "msg": "couchbase not running",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = nodes.get(item)
    if data == None:
        return {"changed": False, "msg": "no such node: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    util = _to_float(data.get("cpu_utilization_rate"))
    if util == None:
        return {"changed": False, "msg": "no cpu data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    state = _grade_upper(util, warn, crit)
    return {"changed": False,
            "msg": "Couchbase CPU utilization of %s is %s%%" % (item, str(util)),
            "data": {"state": state, "metrics": {"cpu_util": util}, "details": ""}}


def _read_nodes(ctx):
    res = ctx.run(["curl", "-s", "-u", "Administrator:password",
                   "http://localhost:8091/pools/default"], mutates=False)
    if res.rc != 0 or not res.stdout:
        res2 = ctx.run(["couchbase-cli", "server-list",
                        "-c", "localhost:8091", "-u", "Administrator", "-p", "password"],
                       mutates=False)
        if res2.rc != 0 or not res2.stdout:
            return {}
        text = res2.stdout
    else:
        text = res.stdout

    if not text:
        return {}
    data = json.decode(text)
    if type(data) != "dict" or not data:
        return {}

    nodes = {}
    node_list = data.get("nodes", [])
    for node in node_list:
        name = node.get("hostname") or node.get("name") or node.get("address")
        if name == None:
            continue
        nodes[name] = node
    if nodes:
        return nodes

    if res.rc == 0 and res.stdout:
        return _parse_cli_nodes(res.stdout)
    return {}


def _parse_cli_nodes(text):
    return {}


def _to_float(v):
    if type(v) == "int" or type(v) == "float":
        return float(v)
    if type(v) == "string":
        try_val = v.replace(".", "", 1)
        if try_val.isdigit():
            return float(v)
    return None


def _grade_upper(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"