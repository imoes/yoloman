# couchbase_nodes_size_docs — read-only Starlark check module.
#
# Translates the Checkmk "couchbase_nodes_size" family of checks into a
# read-only probe that gathers its data from the real on-host source: the
# running Couchbase Server's REST API at /pools/default/nodes, queried via
# curl (the same data the Checkmk special-datas collector reads).
#
# Two modes, selected by params.get("_discover"):
#   - discovery: enumerate Couchbase nodes as items, each exposing the
#     "size_on_disk" and "data_size" metrics.
#   - check:    grade one node's size fields against the warn/crit levels
#     passed in params (Checkmk ruleset couchbase_size_docs).
#
# This module never mutates the system and always reports changed=False.

def _render_bytes(n):
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    val = float(n)
    idx = 0
    while idx < len(units) - 1 and val >= 1024:
        val = val / 1024.0
        idx = idx + 1
    return "%f %s" % (val, units[idx])


def _grade(value, levels, label):
    """Grade an upper-bound metric. levels is (warn, crit) or None.
    Returns (state, msg, metric_value).
    """
    if value == None:
        return ("UNKNOWN", label + ": no data", None)
    metric = value
    warn = levels[0] if levels != None and len(levels) >= 1 else None
    crit = levels[1] if levels != None and len(levels) >= 2 else None
    state = "OK"
    if crit != None and metric >= crit:
        state = "CRIT"
    elif warn != None and metric >= warn:
        state = "WARN"
    msg = "%s: %s" % (label, _render_bytes(metric))
    if state != "OK":
        msg = msg + " (levels %s)" % (str(levels) if levels != None else "none")
    return (state, msg, metric)


def _worse(a, b):
    rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    ra = rank.get(a, 0)
    rb = rank.get(b, 0)
    return a if ra >= rb else b


def _keys_for_plugin(plugin):
    if plugin == "spacial":
        return ("couch_spatial_disk_size", "couch_spatial_data_size")
    if plugin == "couch":
        return ("couch_views_actual_disk_size", "couch_views_data_size")
    return ("couch_docs_actual_disk_size", "couch_docs_data_size")


def _collect_nodes(ctx, host, username, password, port):
    """Query the Couchbase REST API; return {node_name: {field: value}}
    or None when Couchbase is unreachable / not installed on this host.
    """
    url = "http://%s:%s/pools/default/nodes" % (host, str(port))
    cmd = ["curl", "-fsS", "-u", "%s:%s" % (username, password), url]
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return None
    if not res.stdout:
        return None
    doc = json.decode(res.stdout)
    if doc == None:
        return None
    out = doc
    if type(out) != "dict":
        return {}
    arr = out.get("nodes", [])
    if type(arr) != "list":
        return {}
    nodes = {}
    for entry in arr:
        if type(entry) != "dict":
            continue
        name = entry.get("name")
        if name == None:
            continue
        nodes[name] = entry
    return nodes


def main(ctx, params):
    plugin = params.get("couchbase_plugin", "docs")
    host = params.get("host", "localhost")
    username = params.get("username", "")
    password = params.get("password", "")
    port = params.get("port", 8091)

    # Per-metric level thresholds (Checkmk ruleset couchbase_size_docs).
    level_disk = params.get("size_on_disk")
    level_size = params.get("size")
    key_disk, key_size = _keys_for_plugin(plugin)

    if params.get("_discover"):
        section = _collect_nodes(ctx, host, username, password, port)
        if section == None or len(section) == 0:
            return {
                "changed": False,
                "msg": "Couchbase not reachable on %s - no nodes discovered" % host,
                "data": {"discovery": []},
            }
        discovery = []
        for item in section:
            discovery.append({
                "item": item,
                "params": {
                    "size_on_disk": level_disk,
                    "size": level_size,
                },
                "metrics": ["size_on_disk", "data_size"],
            })
        return {
            "changed": False,
            "msg": "discovered %d couchbase nodes" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    section = _collect_nodes(ctx, host, username, password, port)
    if section == None:
        return {
            "changed": False,
            "msg": "Couchbase not reachable on %s" % host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "node %s not found in couchbase nodes" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    details = ""
    worst = "OK"
    on_disk = data.get(key_disk)
    size = data.get(key_size)

    if on_disk != None:
        st, m, mv = _grade(on_disk, level_disk, "Size on disk")
        metrics["size_on_disk"] = mv
        details = details + m + "; "
        worst = _worse(worst, st)
    else:
        details = details + "Size on disk: no data; "
        worst = _worse(worst, "UNKNOWN")

    if size != None:
        st, m, mv = _grade(size, level_size, "Data size")
        metrics["data_size"] = mv
        details = details + m + "; "
        worst = _worse(worst, st)
    else:
        details = details + "Data size: no data; "
        worst = _worse(worst, "UNKNOWN")

    summary = "node %s: %s" % (item, details.rstrip("; "))
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": worst, "metrics": metrics, "details": details},
    }