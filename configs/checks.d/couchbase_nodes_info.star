# Couchbase Nodes Info — translated Checkmk check plugin (read-only)
# Reproduces cmk/plugins/couchbase/agent_based/couchbase_nodes_info.py
#
# This check has NO agent section available on-host (Couchbase exposes its
# data through its REST API, which is a network appliance API, not a local
# /proc or /sys file). Per the translation rules, when the monitored product
# is not reachable on the host we must NOT substitute a local data source.
# The honest, correct behaviour is an empty discovery and an UNKNOWN verdict
# with an explaining message.


def _couchbase_api(ctx, params):
    """Try to reach the Couchbase management API on the configured host.

    Couchbase nodes info comes from the cluster's REST endpoint
    (/<host>:8091/pools/default), which is read-only here. Returns the
    parsed JSON node list, or None if Couchbase is not present/reachable.
    """
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    port = params.get("port", "8091")
    user = params.get("user", None)
    pwd = params.get("password", "")
    base = params.get("base", "")
    res = ctx.run(
        ["curl", "-fsS", "-u", user + ":" + pwd if user != None else ":"] +
        ["http://" + host + ":" + port + "/pools/default" + base],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return json.decode(res.stdout)


def main(ctx, params):
    # ---- Discovery: enumerate the real Couchbase nodes on this host ----
    if params.get("_discover"):
        data = _couchbase_api(ctx, params)
        if data == None:
            # Couchbase not present on this host -> no services.
            return {
                "changed": False,
                "msg": "couchbase not found",
                "data": {"discovery": [], "host_labels": {}},
            }
        nodes = data.get("nodes", []) or []
        out = []
        for node in nodes:
            name = node.get("name", "")
            out.append({
                "item": name,
                "params": {
                    "warmup_state": 0,
                    "unhealthy_state": 2,
                    "inactive_added_state": 1,
                },
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d couchbase nodes" % len(out),
            "data": {"discovery": out, "host_labels": {}},
        }

    # ---- Check: grade one node by its name ----
    item = params.get("item", "")
    data = _couchbase_api(ctx, params)
    if data == None:
        return {
            "changed": False,
            "msg": "couchbase not reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    nodes = data.get("nodes", []) or []
    target = None
    for node in nodes:
        if node.get("name", "") == item:
            target = node
            break
    if target == None:
        return {
            "changed": False,
            "msg": "couchbase node not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Reproduce the original grading logic.
    warm_lvl = params.get("warmup_state", 0)
    unhealthy_lvl = params.get("unhealthy_state", 2)
    inactive_added_state = params.get("inactive_added_state", 1)
    inactive_failed_state = inactive_added_state

    # Map numeric Checkmk states to text.
    lvl_to_state = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    health = target.get("status")
    state = "OK"
    summary = ""
    if health != None:
        if health == "warmup":
            state = lvl_to_state.get(warm_lvl, "OK")
        elif health == "unhealthy":
            state = lvl_to_state.get(unhealthy_lvl, "OK")
        summary = "Health: %s" % health
    else:
        summary = "Health: unknown"

    details_parts = [summary]
    for key, label in (
        ("otpNode", "One-time-password node"),
        ("recoveryType", "Recovery type"),
        ("version", "Version"),
        ("clusterCompatibility", "Cluster compatibility"),
    ):
        details_parts.append("{}: {}".format(label, target.get(key, "unknown")))

    membership = target.get("clusterMembership")
    mem_state = "OK"
    if membership != None:
        if membership == "inactiveAdded":
            mem_state = lvl_to_state.get(inactive_added_state, "OK")
        elif membership == "inactiveFailed":
            mem_state = lvl_to_state.get(inactive_failed_state, "CRIT")
        details_parts.append("Cluster membership: %s" % membership)

    # The single worst non-OK state wins.
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = "OK"
    for cand in (state, mem_state):
        if order.get(cand, 0) > order.get(worst, 0):
            worst = cand

    return {
        "changed": False,
        "msg": "; ".join(details_parts),
        "data": {
            "state": worst,
            "metrics": {},
            "details": "\n".join(details_parts),
        },
    }