def main(ctx, params):
    if params.get("_discover"):
        uptime_data = ctx.stat("/proc/uptime")
        if uptime_data == None:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
        content = ""
        if ctx.file_exists("/proc/uptime"):
            content = ctx.file_read("/proc/uptime")
        if not content.strip():
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["uptime"]}
            ]}
        }

    uptime_data = ctx.stat("/proc/uptime")
    if uptime_data == None:
        return {
            "changed": False,
            "msg": "Uptime file /proc/uptime not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    content = ""
    if ctx.file_exists("/proc/uptime"):
        content = ctx.file_read("/proc/uptime")
    if not content.strip():
        return {
            "changed": False,
            "msg": "Empty uptime file",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    lines = content.strip().split("\n")
    if len(lines) == 0 or not lines[0]:
        return {
            "changed": False,
            "msg": "Empty uptime file",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    parts = lines[0].strip().split()
    uptime_seconds = float(parts[0]) if parts[0].replace(".", "").replace("e", "").replace("E", "").isdigit() or (parts[0].count(".") == 1 and parts[0].replace(".", "").replace("e", "").replace("E", "").isdigit()) else 0.0
    days = int(uptime_seconds) // 86400
    hours = (int(uptime_seconds) % 86400) // 3600
    minutes = (int(uptime_seconds) % 3600) // 60
    seconds = int(uptime_seconds) % 60
    msg_parts = []
    if days:
        msg_parts.append("%d days" % days)
    if hours:
        msg_parts.append("%d hours" % hours)
    if minutes:
        msg_parts.append("%d minutes" % minutes)
    if seconds:
        msg_parts.append("%d seconds" % seconds)
    uptime_str = ", ".join(msg_parts) if msg_parts else "0 seconds"
    return {
        "changed": False,
        "msg": "Uptime: " + uptime_str,
        "data": {
            "state": "OK",
            "metrics": {"uptime": uptime_seconds},
            "details": ""
        }
    }