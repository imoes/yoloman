STATE_MAP = {
    "1": "OK",
    "2": "WARN",
    "3": "CRIT",
    "4": "UNKNOWN",
}

STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _health_state(level_val):
    return STATE_MAP.get(str(level_val), "UNKNOWN")

def _worst_state(a, b):
    if STATE_ORDER.get(a, 3) >= STATE_ORDER.get(b, 3):
        return a
    return b

def _fetch(ctx, host, username, password):
    res = ctx.run([
        "curl", "-sk", "-u", username + ":" + password,
        "-H", "Accept: application/json",
        "https://" + host + "/rest/storeonce/clusterSummary",
    ], mutates=False)
    if res.rc != 0:
        return None
    body = res.stdout.strip()
    if not body.startswith("{"):
        return None
    return json.decode(body)

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "Admin")
    password = params.get("password", "")

    if params.get("_discover"):
        data = _fetch(ctx, host, username, password)
        if data == None:
            return {"changed": False, "msg": "no data from %s" % host,
                    "data": {"discovery": []}}
        summary = data.get("clusterSummary", data)
        if summary.get("clusterHealth") == None:
            return {"changed": False, "msg": "no cluster health in response",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 appliance status service",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": []},
            ]},
        }

    data = _fetch(ctx, host, username, password)
    if data == None:
        return {
            "changed": False,
            "msg": "failed to get cluster info from %s" % host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    summary = data.get("clusterSummary", data)

    cluster_status = summary.get("clusterStatus", "unknown")
    replication_status = summary.get("replicationStatus", "unknown")
    cluster_health_level = summary.get("clusterHealthLevel", 4)
    cluster_health = summary.get("clusterHealth", "unknown")
    replication_health_level = summary.get("replicationHealthLevel", 4)
    replication_health = summary.get("replicationHealth", "unknown")

    cluster_state = _health_state(cluster_health_level)
    replication_state = _health_state(replication_health_level)
    overall = _worst_state(cluster_state, replication_state)

    msg = "Cluster Status: %s, Replication Status: %s" % (cluster_status, replication_status)
    details = "Cluster Health: %s, Replication Health: %s" % (cluster_health, replication_health)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall,
            "metrics": {},
            "details": details,
        },
    }