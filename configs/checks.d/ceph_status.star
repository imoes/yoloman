def main(ctx, params):
    # Discovery mode: plugin was replaced in 2.4.0, do not discover anything
    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 0 services", "data": {"discovery": []}}

    # Read ceph status JSON via command
    res = ctx.run(["ceph", "status", "--format", "json"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "ceph status command failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    section = json.decode(res.stdout)

    # Parse section: handle both old and new ceph health format
    health = section.get("health", {})
    if "status" not in health and "overall_status" in health:
        health["status"] = health["overall_status"]

    # Map health status to Checkmk states
    map_health_states = {
        "HEALTH_OK": ("OK", "OK"),
        "HEALTH_WARN": ("WARN", "warning"),
        "HEALTH_CRIT": ("CRIT", "critical"),
        "HEALTH_ERR": ("CRIT", "error"),
    }

    overall_status = health.get("status")
    if not overall_status:
        return {
            "changed": False,
            "msg": "no health status available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    state_info = map_health_states.get(overall_status, ("UNKNOWN", "unknown[%s]" % overall_status))
    state_readable = state_info[1]
    state = state_info[0]

    # Extract error messages if state is not OK
    if state != "OK":
        error_messages = []
        checks = health.get("checks", {})
        for err in checks.values():
            summary = err.get("summary", {})
            err_msg = summary.get("message")
            if err_msg:
                error_messages.append(err_msg)
        if error_messages:
            error_messages.sort()
            state_readable += " (%s)" % (", ".join(error_messages))

    msg = "Health: %s" % state_readable
    metrics = {}

    # Epoch rate check (ceph_status) - skip rate calculation due to Starlark limitations
    election_epoch = section.get("election_epoch")
    if election_epoch != None:
        metrics["election_epoch"] = int(election_epoch)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
