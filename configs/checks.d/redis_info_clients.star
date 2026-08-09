def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 0 Redis instances",
            "data": {"discovery": []},
        }
    item = params.get("item", "")
    warn_upper = params.get("connected_upper")
    crit_upper = params.get("connected_upper")
    warn_lower = params.get("connected_lower")
    crit_lower = params.get("connected_lower")
    state = "UNKNOWN"
    msg = "redis_info clients check: no source available"
    metrics = {}
    details = ""
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": details},
    }