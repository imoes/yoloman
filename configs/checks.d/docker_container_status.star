def _parse_datetime_safe(s):
    # naive parsing for ISO 8601 like "2024-01-01T00:00:00.000000000Z"
    if not s:
        return 0
    s = s.strip()
    # remove trailing Z
    s = s.replace("Z", "")
    if len(s) < 10:
        return 0
    date_part = s.split("T")[0]
    time_part = s.split("T")[1] if len(s.split("T")) > 1 else "00:00:00"
    date_parts = date_part.split("-")
    year_str = date_parts[0] if len(date_parts) >= 1 else ""
    month_str = date_parts[1] if len(date_parts) >= 2 else "1"
    day_str = date_parts[2] if len(date_parts) >= 3 else "1"
    year = int(year_str) if year_str.isdigit() else 0
    month = int(month_str) if month_str.isdigit() else 1
    day = int(day_str) if day_str.isdigit() else 1
    hour = 0
    minute = 0
    second = 0
    time_parts = time_part.split(":")
    if len(time_parts) >= 1 and time_parts[0].isdigit():
        hour = int(time_parts[0])
    if len(time_parts) >= 2 and time_parts[1].isdigit():
        minute = int(time_parts[1])
    if len(time_parts) >= 3:
        sec_str = time_parts[2].split(".")[0]
        if sec_str.isdigit():
            second = int(sec_str)
    # compute seconds since epoch (approximate)
    days = (year - 1970) * 365 + (year - 1969) // 4 - (year - 1901) // 100 + (year - 1601) // 400 + day - 1
    month_days = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    days += month_days[month - 1]
    if month > 2 and (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)):
        days += 1
    return days * 86400 + hour * 3600 + minute * 60 + second

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["docker", "inspect", "self"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 containers",
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "discovered 0 containers",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        if len(data) == 0:
            return {"changed": False, "msg": "discovered 0 containers",
                    "data": {"discovery": []}}

        container = data[0]
        section = container

        status = section.get("State", {}).get("Status", "")
        restart_policy = section.get("HostConfig", {}).get("RestartPolicy", {}).get("Name", "")
        is_active = (status in ("running", "exited")) or restart_policy in ("always",)

        if not is_active:
            return {"changed": False, "msg": "discovered 0 services",
                    "data": {"discovery": []}}

        discovery = []
        discovery.append({"item": "", "params": {}, "metrics": []})

        healthcheck = section.get("Config", {}).get("Healthcheck")
        health = section.get("State", {}).get("Health")
        if healthcheck and health:
            discovery.append({"item": "", "params": {}, "metrics": []})

        started_at = section.get("State", {}).get("StartedAt")
        if is_active and started_at:
            discovery.append({"item": "", "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d services" % len(discovery),
                "data": {"discovery": discovery}}

    res = ctx.run(["docker", "inspect", "self"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "cannot inspect container",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if len(data) == 0:
        return {"changed": False, "msg": "no container data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    container = data[0]
    section = container
    state_info = section.get("State", {})
    status = state_info.get("Status", "unknown")
    node_name = section.get("Node", {}).get("ID")
    if not node_name:
        node_name = section.get("Node", {}).get("Name")

    cur_state = "OK"
    if status == "unknown":
        cur_state = "UNKNOWN"
    elif status != "running":
        cur_state = "CRIT"

    info = "Container %s" % status
    if node_name:
        info += " on node %s" % node_name

    health_status = "unknown"
    health_report = ""
    health_exit_code = 0
    failing_streak = "not found"
    health_test = ""

    healthcheck = section.get("Config", {}).get("Healthcheck")
    health = state_info.get("Health")
    if healthcheck and health:
        health_status = health.get("Status", "unknown")
        health_status_map = {"healthy": "OK", "starting": "WARN", "unhealthy": "CRIT"}
        cur_state_health = health_status_map.get(health_status, "UNKNOWN")
        if cur_state == "OK":
            cur_state = cur_state_health

        log_entries = health.get("Log") or [{}]
        last_log = log_entries[-1] if len(log_entries) > 0 else {}
        health_report = last_log.get("Output", "no output").strip().replace("\n", ", ")
        health_exit_code = last_log.get("ExitCode", 0)

        if cur_state_health == "CRIT":
            failing_streak = health.get("FailingStreak", "not found")

        health_test = healthcheck.get("Test")

    if section.get("State", {}).get("Error"):
        cur_state = "CRIT"
        info += ", Error: %s" % section["State"]["Error"]

    started_at = state_info.get("StartedAt")
    uptime_info = ""
    if started_at:
        utc_start = _parse_datetime_safe(started_at)
        if utc_start > 0:
            now_res = ctx.run(["date", "+%s"], mutates=False)
            now_ts = 0
            if now_res.rc == 0 and now_res.stdout.strip().isdigit():
                now_ts = int(now_res.stdout.strip())
            if now_ts > 0 and now_ts >= utc_start:
                uptime_sec = now_ts - utc_start
                uptime_days = uptime_sec // 86400
                uptime_hours = (uptime_sec % 86400) // 3600
                uptime_mins = (uptime_sec % 3600) // 60
                uptime_info = ", Uptime: %d d %d h %d m" % (uptime_days, uptime_hours, uptime_mins)

    final_summary = info
    if uptime_info:
        final_summary += uptime_info
    if healthcheck and health and health_status != "healthy":
        final_summary = "Health status: %s" % health_status.title()
        if health_report:
            final_summary += ", Last report: %s" % health_report

    metrics = {}
    if started_at and status == "running":
        utc_start = _parse_datetime_safe(started_at)
        if utc_start > 0:
            now_res = ctx.run(["date", "+%s"], mutates=False)
            now_ts = 0
            if now_res.rc == 0 and now_res.stdout.strip().isdigit():
                now_ts = int(now_res.stdout.strip())
            if now_ts > 0 and now_ts >= utc_start:
                uptime_sec = now_ts - utc_start
                metrics["uptime"] = uptime_sec

    return {"changed": False,
            "msg": final_summary,
            "data": {"state": cur_state,
                     "metrics": metrics,
                     "details": ""}}