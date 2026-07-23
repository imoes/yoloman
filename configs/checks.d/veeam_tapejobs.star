_DAY = 86400  # 3600 * 24

def main(ctx, params):
    if params.get("_discover"):
        section_path = "/var/lib/check-mk-agent/raw/veeam_tapejobs"
        if not ctx.file_exists(section_path):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        raw = ctx.file_read(section_path)
        lines = raw.split("\n")
        if len(lines) < 2:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        columns = [s.lower() for s in lines[0].split()]
        out = []
        for line in lines[1:]:
            fields = line.split()
            if len(fields) < len(columns):
                continue
            name = " ".join(fields[: -(len(columns) - 1)])
            job_id = fields[-(len(columns) - 1)]
            last_result = fields[-(len(columns) - 2)]
            last_state = fields[-(len(columns) - 3)]
            out.append({"item": name, "params": {"levels_upper": (1 * _DAY, 2 * _DAY)},
                        "metrics": ["running_time"]})
        return {"changed": False, "msg": "discovered %d tape jobs" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    section_path = "/var/lib/check-mk-agent/raw/veeam_tapejobs"
    if not ctx.file_exists(section_path):
        return {"changed": False, "msg": "no veeam_tapejobs section available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = ctx.file_read(section_path)
    lines = raw.split("\n")
    if len(lines) < 2:
        return {"changed": False, "msg": "no veeam_tapejobs section available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    columns = [s.lower() for s in lines[0].split()]
    job_data = None
    for line in lines[1:]:
        fields = line.split()
        if len(fields) < len(columns):
            continue
        name = " ".join(fields[: -(len(columns) - 1)])
        if name == item:
            job_id = fields[-(len(columns) - 1)]
            last_result = fields[-(len(columns) - 2)]
            last_state = fields[-(len(columns) - 3)]
            job_data = {"job_id": job_id, "last_result": last_result, "last_state": last_state}
            break

    if job_data == None:
        return {"changed": False, "msg": "tape job not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    job_id = job_data.get("job_id", "")
    last_result = job_data.get("last_result", "")
    last_state = job_data.get("last_state", "")

    def state_for_result(res):
        if res == "Success":
            return "OK"
        elif res == "Warning":
            return "WARN"
        elif res == "Failed":
            return "CRIT"
        return "CRIT"

    if last_result != "None" or (last_state not in ["Working", "Idle"]):
        return {
            "changed": False,
            "msg": "Last backup result: " + last_result + ", Last state: " + last_state,
            "data": {
                "state": state_for_result(last_result),
                "metrics": {},
                "details": "Last state: " + last_state,
            },
        }

    store_key = "veeam_tapejobs_" + job_id
    store_path = "/tmp/" + store_key
    running_since = None
    if ctx.file_exists(store_path):
        running_since_str = ctx.file_read(store_path)
        if running_since_str.isdigit():
            running_since = float(running_since_str)

    now = 0.0
    # Get current time via /proc/uptime on Linux or equivalent
    if ctx.file_exists("/proc/uptime"):
        uptime_raw = ctx.file_read("/proc/uptime")
        parts = uptime_raw.split()
        if len(parts) >= 1 and parts[0].replace(".", "").isdigit():
            now = float(parts[0])
    else:
        # Fallback: use current Unix time via command (read-only)
        res = ctx.run(["date", "+%s"])
        if res.rc == 0:
            now = float(res.stdout.strip())

    if running_since == None:
        running_since = now

    # Do not persist running_since in check_mode
    if not ctx.check_mode and running_since == now:
        ctx.file_write(store_path, str(now))

    running_time = now - running_since

    warn, crit = params.get("levels_upper", (1 * _DAY, 2 * _DAY))
    state = "CRIT" if running_time >= crit else ("WARN" if running_time >= warn else "OK")

    def format_timespan(seconds):
        days = int(seconds // 86400)
        hours = int((seconds % 86400) // 3600)
        mins = int((seconds % 3600) // 60)
        secs = int(seconds % 60)
        parts = []
        if days > 0:
            parts.append(str(days) + "d")
        if hours > 0:
            parts.append(str(hours) + "h")
        if mins > 0:
            parts.append(str(mins) + "m")
        parts.append(str(secs) + "s")
        return " ".join(parts)

    return {
        "changed": False,
        "msg": "Backup in progress (currently " + last_state.lower() + "), Running time: " + format_timespan(running_time),
        "data": {
            "state": state,
            "metrics": {"running_time": running_time},
            "details": "",
        },
    }
