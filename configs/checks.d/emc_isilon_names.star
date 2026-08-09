def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sysDescr = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysDescr.rc != 0 or sysDescr.skipped:
            return {"changed": False, "msg": "no data", "data": {"discovery": []}}
        if "isilon" not in sysDescr.stdout:
            return {"changed": False, "msg": "not an Isilon", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["cluster_health", "node_health", "configured_nodes", "online_nodes", "cluster_name", "node_name"],
                    }
                ]
            },
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.12124"

    # Fetch cluster name + health (tree 1.1)
    tree1 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1.1"],
        mutates=False,
    )
    # Fetch node name + health (tree 2.1)
    tree2 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".2.1"],
        mutates=False,
    )

    if tree1.rc != 0 or tree2.rc != 0 or tree1.skipped or tree2.skipped:
        return {
            "changed": False,
            "msg": "Isilon data ungatherable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse tree1: base ".1.3.6.1.4.1.12124.1.1", oids 1 (clusterName), 2 (cluster Health), 5 (configuredNodes), 6 (onlineNodes)
    t1 = _parse_walk(tree1.stdout, base + ".1.1")
    # Parse tree2: base ".1.3.6.1.4.1.12124.2.1", oids 1 (nodeName), 2 (nodeHealth)
    t2 = _parse_walk(tree2.stdout, base + ".2.1")

    if not t1 or not t2:
        return {
            "changed": False,
            "msg": "Isilon section empty",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # t1[0] = clusterName, t1[1] = clusterHealth, t1[4] = configuredNodes, t1[5] = onlineNodes
    # t2[0] = nodeName, t2[1] = nodeHealth
    cluster_name = _get_val(t1, 1, "clusterName")
    cluster_health = _get_val(t1, 2, "clusterHealth")
    configured_nodes = _get_val(t1, 5, "configuredNodes")
    online_nodes = _get_val(t1, 6, "onlineNodes")
    node_name = _get_val(t2, 1, "nodeName")
    node_health = _get_val(t2, 2, "nodeHealth")

    cluster_statusmap = ("ok", "attn", "down", "invalid")
    node_statusmap = ("ok", "attn", "down", "invalid")

    state = "OK"

    # Cluster health
    if cluster_health != None and cluster_health.isdigit():
        cs = int(cluster_health)
        if cs >= len(cluster_statusmap):
            return {
                "changed": False,
                "msg": "ClusterHealth reports unidentified status %s" % cluster_health,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        cstate_str = cluster_statusmap[cs]
        if cs != 0:
            state = _worse(state, "CRIT")
    else:
        cstate_str = "?"

    # Node health
    if node_health != None and node_health.isdigit():
        ns = int(node_health)
        if ns >= len(node_statusmap):
            return {
                "changed": False,
                "msg": "nodeHealth reports unidentified status %s" % node_health,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        nstate_str = node_statusmap[ns]
        if ns != 0:
            state = _worse(state, "CRIT")
    else:
        nstate_str = "?"

    # Nodes
    if configured_nodes != None and online_nodes != None:
        n_nodes = "CRIT" if configured_nodes != online_nodes else "OK"
        if configured_nodes != online_nodes:
            state = _worse(state, "CRIT")
    else:
        n_nodes = "?"

    msg = "Cluster Name is %s, Node Name is %s" % (cluster_name, node_name)

    metrics = {}
    if cluster_health != None and cluster_health.isdigit():
        metrics["cluster_health"] = int(cluster_health)
    if node_health != None and node_health.isdigit():
        metrics["node_health"] = int(node_health)
    if configured_nodes != None and configured_nodes.isdigit():
        metrics["configured_nodes"] = int(configured_nodes)
    if online_nodes != None and online_nodes.isdigit():
        metrics["online_nodes"] = int(online_nodes)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }


def _parse_walk(stdout, base):
    result = {}
    for line in stdout.splitlines():
        sp = line.find(" ")
        if sp <= 0:
            continue
        oid = line[:sp]
        val = line[sp+1:]
        if not oid.startswith(base):
            continue
        suffix = oid[len(base)+1:]
        result[suffix] = val
    return result


def _get_val(table, col, label):
    return table.get(str(col))


def _worse(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(a, 3) >= order.get(b, 3):
        return a
    return b