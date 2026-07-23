STATE_MAP = {"1": "OK", "2": "WARN", "3": "CRIT"}

def _level_state(level):
    return STATE_MAP.get(str(level), "UNKNOWN")

def _worst(states):
    if "CRIT" in states:
        return "CRIT"
    if "WARN" in states:
        return "WARN"
    if "UNKNOWN" in states:
        return "UNKNOWN"
    return "OK"

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "monitor")
    password = params.get("password", "")
    port = params.get("port", 443)

    url = "https://%s:%d/api/v4/management-facilities" % (host, port)
    res = ctx.run(
        ["curl", "-k", "-s", "--max-time", "30",
         "-u", username + ":" + password,
         "-H", "Accept: application/json",
         url],
        mutates=False,
    )

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "curl error (rc=%d)" % res.rc,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr[:200]},
        }

    stdout = res.stdout.strip()
    if not stdout:
        return {
            "changed": False,
            "msg": "empty response from StoreOnce API",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = json.decode(stdout)
    members = data.get("members", [])

    if params.get("_discover"):
        discovery = []
        for m in members:
            item_id = str(m.get("id", ""))
            discovery.append({
                "item": item_id,
                "params": {},
                "metrics": ["ss_health_level", "replication_health_level", "housekeeping_health_level"],
            })
        return {
            "changed": False,
            "msg": "discovered %d service sets" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    target = None
    for m in members:
        if str(m.get("id", "")) == item:
            target = m
            break

    if target == None:
        return {
            "changed": False,
            "msg": "service set %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    alias = target.get("alias", "")
    name = target.get("name", "")
    overall_status = target.get("overallStatus", "unknown")
    overall_health = target.get("overallHealth", "unknown")

    if alias:
        prefix = "Alias: %s, " % alias
    elif name:
        prefix = "Name: %s, " % name
    else:
        prefix = ""
    msg = "%sOverall Status: %s, Overall Health: %s" % (prefix, overall_status, overall_health)

    ss_level = str(target.get("serviceSetHealthLevel", "1"))
    ss_health = target.get("serviceSetHealth", "OK")
    repl_level = str(target.get("replicationHealthLevel", "1"))
    repl_health = target.get("replicationHealth", "OK")
    hk_level = str(target.get("housekeepingHealthLevel", "1"))
    hk_health = target.get("housekeepingHealth", "OK")

    worst = _worst([_level_state(ss_level), _level_state(repl_level), _level_state(hk_level)])

    details = "ServiceSet Health: %s; Replication Health: %s; Housekeeping Health: %s" % (
        ss_health, repl_health, hk_health)

    metrics = {
        "ss_health_level": int(ss_level) if ss_level.isdigit() else 0,
        "replication_health_level": int(repl_level) if repl_level.isdigit() else 0,
        "housekeeping_health_level": int(hk_level) if hk_level.isdigit() else 0,
    }

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": worst, "metrics": metrics, "details": details},
    }