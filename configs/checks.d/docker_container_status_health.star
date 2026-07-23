def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["docker", "inspect", "host"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 containers (docker inspect failed)",
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "discovered 0 containers (no docker inspect output)",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        out = []
        if type(data) == "list":
            for container in data:
                if type(container) != "dict":
                    continue
                status = container.get("State", {}).get("Status", "")
                restart_policy = container.get("HostConfig", {}).get("RestartPolicy", {}).get("Name", "")
                is_active = status in ("running", "exited") or restart_policy in ("always",)
                healthcheck = container.get("Config", {}).get("Healthcheck")
                health = container.get("State", {}).get("Health")
                if is_active and healthcheck and health:
                    out.append({"item": "", "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d container health services" % len(out),
                "data": {"discovery": out}}
    
    # Check mode: inspect the host container
    res = ctx.run(["docker", "inspect", "host"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Docker inspect failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "Docker inspect JSON invalid",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    
    if type(data) != "list" or len(data) == 0:
        return {"changed": False, "msg": "No container data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    container = data[0] if type(data[0]) == "dict" else None
    if container == None:
        return {"changed": False, "msg": "Invalid container data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    health = container.get("State", {}).get("Health", {})
    status = health.get("Status", "unknown")
    
    # Map health status to Checkmk states
    health_status_map = {
        "healthy": "OK",
        "starting": "WARN",
        "unhealthy": "CRIT",
    }
    state = health_status_map.get(status, "UNKNOWN")
    
    # Get last health report
    log = health.get("Log", [{}])
    last_log = log[-1] if len(log) > 0 else {}
    health_report = last_log.get("Output", "no output")
    if health_report:
        health_report = health_report.strip().replace("\n", ", ")
    exit_code = last_log.get("ExitCode", 0)
    report_state = "OK" if int(exit_code) == 0 else "CRIT"
    
    # Build summary
    summary = "Health status: %s" % status.title()
    
    # Get failing streak for unhealthy containers
    details = ""
    if state == "CRIT":
        failing_streak = health.get("FailingStreak", "not found")
        details = "Failing streak: %s" % failing_streak
    
    # Health test info
    healthcheck = container.get("Config", {}).get("Healthcheck", {})
    health_test = healthcheck.get("Test", [])
    if len(health_test) > 0:
        test_str = " ".join(health_test).strip()
        if test_str:
            details = details + "\n" + test_str if details else test_str
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }