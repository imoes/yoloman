def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["podman", "ps", "-a", "--format", "{{.Status}}|{{.PodName}}"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "podman not installed", "data": {"discovery": []}}
        if len(res.stdout.strip()) == 0:
            return {"changed": False, "msg": "no pods found", "data": {"discovery": []}}

        metrics = []
        for state in ["total", "running", "created", "stopped", "dead", "exited", "paused", "degraded"]:
            metrics.append("podman_pods_" + state + "_number")

        return {
            "changed": False,
            "msg": "discovered Podman pods",
            "data": {
                "discovery": [{"item": "", "params": {"dead": {"levels_upper": [1, 1]}}, "metrics": metrics}],
            },
        }

    item = params.get("item", "")
    res = ctx.run(["podman", "ps", "-a", "--format", "{{.Status}}|{{.PodName}}"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "podman not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    counts = {
        "total": 0,
        "running": 0,
        "created": 0,
        "stopped": 0,
        "dead": 0,
        "exited": 0,
        "paused": 0,
        "degraded": 0,
    }

    for line in res.stdout.splitlines():
        parts = line.split("|", 1)
        if len(parts) < 2:
            continue
        status = parts[0].lower()
        if status in counts:
            counts[status] = counts[status] + 1

    all_states = ["running", "created", "stopped", "dead", "exited", "paused", "degraded"]
    total = 0
    for s in all_states:
        total = total + counts[s]
    counts["total"] = total

    if counts["total"] == 0:
        return {"changed": False, "msg": "No pods found",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    metrics = {}
    for state in counts:
        metrics["podman_pods_" + state + "_number"] = counts[state]

    msg = "%d pods: %d running, %d stopped, %d dead" % (
        counts["total"], counts["running"], counts["stopped"], counts["dead"])

    state = "OK"
    for state_name in counts:
        sp = params.get(state_name, {})
        if type(sp) == "dict":
            lu = sp.get("levels_upper", [1])
        else:
            lu = [1]
        if type(lu) == "list" or type(lu) == "tuple":
            if len(lu) >= 2 and counts[state_name] >= lu[1]:
                state = "CRIT"
            elif len(lu) >= 1 and counts[state_name] >= lu[0] and state != "CRIT":
                state = "WARN"

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}