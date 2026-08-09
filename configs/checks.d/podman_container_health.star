def main(ctx, params):
    # Discovery mode: always yields a single service
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"healthy": 0, "starting": 0, "unhealthy": 2, "no_healthcheck": 0}, "metrics": []}]}
        }

    # Read podman container inspect JSON output via agent section
    res = ctx.run(["podman", "inspect", "--format=json", "localhost"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "could not retrieve container inspect data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    containers = json.decode(res.stdout)
    if not containers or len(containers) == 0:
        return {
            "changed": False,
            "msg": "no containers found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    container = containers[0]
    state = container.get("State", {})
    health = state.get("Health", {})
    config = container.get("Config", {})

    # Extract health status and related fields
    health_status_str = health.get("Status")  # e.g., "healthy", "unhealthy", "starting", ""
    config_healthcheck = config.get("Healthcheck")
    healthcheck_command = ""
    failing_streak = health.get("FailingStreak", 0)
    health_log = health.get("Log", [])
    last_log = health_log[-1] if health_log else {}
    last_output = last_log.get("Output", "") if last_log else ""
    last_exit_code = last_log.get("ExitCode") if last_log else None

    # Extract healthcheck command string
    if config_healthcheck:
        cmd_list = config_healthcheck.get("Command")
        if cmd_list and len(cmd_list) > 1:
            healthcheck_command = " ".join(cmd_list[1:])

    # Determine effective health status string for lookup
    if not config_healthcheck or not health_status_str:
        health_status = "no_healthcheck"
    else:
        health_status = health_status_str if health_status_str in ["healthy", "unhealthy", "starting"] else "no_healthcheck"

    # Defaults from Checkmk plugin
    healthy = params.get("healthy", 0)
    starting = params.get("starting", 0)
    unhealthy = params.get("unhealthy", 2)
    no_healthcheck = params.get("no_healthcheck", 0)

    # State mapping
    if health_status == "no_healthcheck":
        if not health_status_str:
            state_val = "OK"
            summary = "No health information available"
        else:
            state_val = "UNKNOWN"
            summary = "No health check configured or no health status available"
    elif health_status == "healthy":
        state_val = "OK"
        summary = "Status: healthy"
    elif health_status == "starting":
        state_val = "WARN"
        summary = "Status: starting"
    elif health_status == "unhealthy":
        state_val = "CRIT"
        summary = "Status: unhealthy"
    else:
        state_val = "UNKNOWN"
        summary = "Status: unknown"

    # Build details string
    last_health_report = last_output if last_output else "No health report available"
    details_lines = [
        "Last health report: %s" % last_health_report,
        "Health check command: %s" % (healthcheck_command if healthcheck_command else "No health check command configured"),
        "Consecutive failed healthchecks: %d" % failing_streak,
        "On failure action: %s" % (config_healthcheck.get("OnFailure", "") if config_healthcheck else "Not configured"),
        "Last saved exit code: %s" % (str(last_exit_code) if last_exit_code != None else "N/A"),
    ]
    details = "\n".join(details_lines)

    # Map State string to Checkmk state
    if state_val == "OK":
        state_int = 0
    elif state_val == "WARN":
        state_int = 1
    elif state_val == "CRIT":
        state_int = 2
    else:
        state_int = 3

    # Apply threshold override
    if health_status == "healthy":
        state_int = healthy
    elif health_status == "starting":
        state_int = starting
    elif health_status == "unhealthy":
        state_int = unhealthy
    else:  # no_healthcheck
        state_int = no_healthcheck

    # Convert state_int to Checkmk state string
    if state_int == 0:
        final_state = "OK"
    elif state_int == 1:
        final_state = "WARN"
    elif state_int == 2:
        final_state = "CRIT"
    else:
        final_state = "UNKNOWN"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": final_state,
            "metrics": {},
            "details": details
        }
    }