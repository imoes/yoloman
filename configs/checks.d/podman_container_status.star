def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["podman", "inspect", "--type=container", "--format", "{{json .}}", "_json_"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "no podman containers found", "data": {"discovery": []}}
        if not res.stdout.strip():
            return {"changed": False, "msg": "no podman containers found", "data": {"discovery": []}}
        data = json.decode(res.stdout)
        containers = data if type(data) == "list" else [data]
        discovery = []
        for c in containers:
            name = c.get("Name", "")
            if name == "":
                continue
            discovery.append({"item": name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d containers" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["podman", "inspect", "--type=container", "--format", "{{json .}}", item], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no such podman container: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)
    container = data[0] if type(data) == "list" else data
    state_info = container.get("State", {})
    config = container.get("Config", {})
    pod_name = container.get("Pod", "")

    status = state_info.get("Status", "unknown")
    exit_code = state_info.get("ExitCode", 0)

    if status == "exited" and exit_code == 0:
        resolved = "exited_with_zero"
    elif status == "exited":
        resolved = "exited_with_non_zero"
    else:
        resolved = status

    created = params.get("created", 2)
    running = params.get("running", 0)
    paused = params.get("paused", 2)
    restarting = params.get("restarting", 2)
    removing = params.get("removing", 2)
    exited_zero = params.get("exited_with_zero", 0)
    exited_nonzero = params.get("exited_with_non_zero", 2)
    dead = params.get("dead", 2)

    level_map = {
        "created": created,
        "running": running,
        "paused": paused,
        "restarting": restarting,
        "removing": removing,
        "exited_with_zero": exited_zero,
        "exited_with_non_zero": exited_nonzero,
        "dead": dead,
    }

    level = level_map.get(resolved, 3)
    if level == 0:
        state = "OK"
    elif level == 1:
        state = "WARN"
    elif level == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    finished_at = state_info.get("FinishedAt", "")
    if status == "exited" and finished_at != "":
        ts = finished_at
        if ts.endswith("Z") and len(ts) > 1:
            ts = ts[:-1] + "+00:00"
        summary = "Container %s exited at %s (code %s)" % (item, ts, exit_code)
    else:
        summary = resolved.capitalize() + " %d%%" % level if level != 0 else resolved.capitalize()
        # simpler: just use status-like text
        summary = resolved.capitalize().replace("_", " ")

    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {}, "details": ""}}