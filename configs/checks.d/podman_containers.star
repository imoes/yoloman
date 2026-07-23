def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": [
                "podman_containers_dead_number",
                "podman_containers_exited_as_non_zero_number",
                "podman_containers_exited_number",
                "podman_containers_created_number",
                "podman_containers_paused_number",
                "podman_containers_removing_number",
                "podman_containers_restarting_number",
                "podman_containers_running_number",
                "podman_containers_stopped_number",
                "podman_containers_total_number",
            ]}]}
        }

    # Check mode
    res = ctx.run(["podman", "ps", "-a", "--format", "json"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve podman containers",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no containers found",
            "data": {"state": "OK", "metrics": {"podman_containers_total_number": 0}, "details": ""}
        }

    json_str = res.stdout.strip()
    containers = json.decode(json_str) if json_str else []

    state_counts = {
        "total": 0,
        "running": 0,
        "created": 0,
        "paused": 0,
        "stopped": 0,
        "restarting": 0,
        "removing": 0,
        "dead": 0,
        "exited": 0,
        "exited_as_non_zero": 0,
    }

    for c in containers:
        state_counts["total"] += 1
        state = str(c.get("State", "")).lower()
        exit_code = int(c.get("ExitCode", 0)) if c.get("ExitCode") != None else 0

        if state == "running":
            state_counts["running"] += 1
        elif state == "created":
            state_counts["created"] += 1
        elif state == "paused":
            state_counts["paused"] += 1
        elif state == "stopped":
            state_counts["stopped"] += 1
        elif state == "restarting":
            state_counts["restarting"] += 1
        elif state == "removing":
            state_counts["removing"] += 1
        elif state == "dead":
            state_counts["dead"] += 1
        elif state == "exited":
            state_counts["exited"] += 1
            if exit_code != 0:
                state_counts["exited_as_non_zero"] += 1

    # Use mutable dict to track worst state instead of nonlocal
    state_tracker = {"worst": "OK"}

    # Threshold processing helper
    def check_upper_levels(count, param_dict):
        levels = param_dict.get("levels_upper")
        if levels == None or len(levels) != 2 or levels[0] != "fixed":
            return
        warn, crit = levels[1]
        if count >= crit:
            state_tracker["worst"] = "CRIT"
        elif count >= warn and state_tracker["worst"] != "CRIT":
            state_tracker["worst"] = "WARN"

    # Check all state counts
    for state, count in state_counts.items():
        if state == "total":
            continue
        p = params.get(state, {})
        if not p:
            p = {"levels_upper": ("fixed", (1, 1))} if state in ("dead", "exited_as_non_zero") else {}
        check_upper_levels(count, p)

    msg_parts = []
    for state, count in state_counts.items():
        if state == "total":
            continue
        msg_parts.append("%s: %d" % (state.replace("_", " ").title(), count))

    if state_counts["total"] == 0:
        state = "OK"
        msg = "No containers found"
    else:
        state = state_tracker["worst"]
        msg = ", ".join(msg_parts)

    metrics = {}
    for k, v in state_counts.items():
        metrics["podman_containers_%s_number" % k] = v

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }