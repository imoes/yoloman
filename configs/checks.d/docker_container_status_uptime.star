def main(ctx, params):
    if params.get("_discover"):
        # Discovery: check docker_container_status section is available and active with StartedAt
        res = ctx.run(["cmk-agent-ctl", "list-sections"], mutates=False)
        if "docker_container_status" not in res.stdout:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        # Probe docker_container_status data via agent output
        # Since we cannot invoke checkmk tools, run the raw data source: the same JSON as agent would provide
        # Checkmk agent section 'docker_container_status' is usually from 'docker inspect'
        # Use 'docker inspect --format={{.State.StartedAt}}' for StartedAt, and 'docker inspect' JSON for full status
        res = ctx.run(["docker", "inspect", "--format={{json .}}", ctx.facts().get("hostname", "")], mutates=False)
        # If container name unknown or no docker, fall back to empty discovery
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        if not res.stdout:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        data = json.decode(res.stdout)

        # Single container host case: hostname matches container name
        # For multi-container, we assume hostname is container name or fail gracefully
        if isinstance(data, list) and len(data) > 0:
            container = data[0]
        else:
            container = data

        status = container.get("State", {}).get("Status", "")
        started_at = container.get("State", {}).get("StartedAt", "")
        restart_policy = container.get("HostConfig", {}).get("RestartPolicy", {}).get("Name", "")

        active = status in ("running", "exited") or restart_policy in ("always",)
        if not active or not started_at:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        # Uptime service only if uptime agent section not present (skip discovery if /proc/uptime exists)
        # Since we can't probe agent sections directly, rely on the existence of /proc/uptime as proxy
        if ctx.file_exists("/proc/uptime"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["uptime"]
                    }
                ]
            }
        }

    # Check mode: compute uptime from StartedAt
    res = ctx.run(["docker", "inspect", "--format={{json .}}", ctx.facts().get("hostname", "")], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "Container not found or docker not accessible", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not res.stdout:
        return {"changed": False, "msg": "Container not found or docker not accessible", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)

    if isinstance(data, list) and len(data) > 0:
        container = data[0]
    else:
        container = data

    status = container.get("State", {}).get("Status", "")
    started_at = container.get("State", {}).get("StartedAt", "")

    if not started_at:
        return {"changed": False, "msg": "Container not started", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if status != "running":
        return {"changed": False, "msg": "Operational state: %s" % status, "data": {"state": "OK", "metrics": {}, "details": ""}}

    # Parse StartedAt to epoch seconds using 'date -d <started_at> +%s'
    res = ctx.run(["date", "-d", started_at, "+%s"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "Could not parse StartedAt", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    started_epoch = int(res.stdout.strip())

    # Get current epoch with 'date +%s'
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "Could not get current time", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    now_epoch = int(res.stdout.strip())

    uptime_sec = now_epoch - started_epoch

    # Uptime levels: warn/crit from params with defaults from Checkmk (in seconds)
    # Checkmk default for 'uptime' check: levels=(300, 60) meaning warn if < 60s, crit if < 300s? No:
    # Actually, Checkmk uptime levels are upper thresholds: warn if > warn_sec, crit if > crit_sec.
    # The params dict contains 'levels' tuple (warn, crit) — use defaults if absent.
    warn = params.get("levels", [604800, 2678400])  # default: 7 days / 31 days

    if len(warn) >= 2:
        warn_sec = int(warn[0]) if isinstance(warn[0], int) else 604800
        crit_sec = int(warn[1]) if isinstance(warn[1], int) else 2678400
    else:
        warn_sec = 604800
        crit_sec = 2678400

    # State logic: upper levels -> WARN if > warn, CRIT if > crit
    if uptime_sec >= crit_sec:
        state = "CRIT"
        msg = "Uptime: %s (warn/crit at 7d/31d)" % _format_uptime(uptime_sec)
    elif uptime_sec >= warn_sec:
        state = "WARN"
        msg = "Uptime: %s (warn/crit at 7d/31d)" % _format_uptime(uptime_sec)
    else:
        state = "OK"
        msg = "Uptime: %s (warn/crit at 7d/31d)" % _format_uptime(uptime_sec)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"uptime": uptime_sec},
            "details": ""
        }
    }


def _format_uptime(seconds):
    days = int(seconds // 86400)
    hours = int((seconds % 86400) // 3600)
    mins = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    if days > 0:
        return "%d days, %d:%d:%d" % (days, hours, mins, secs)
    return "%d:%d:%d" % (hours, mins, secs)
