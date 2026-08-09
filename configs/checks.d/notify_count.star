def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    notify_log_path = "/var/log/check_mk/notify.log"
    if not ctx.file_exists(notify_log_path):
        return {
            "changed": False,
            "msg": "notify log not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    content = ctx.file_read(notify_log_path)
    lines = content.split("\n")
    total = 0
    for i in range(len(lines)):
        if lines[i].strip() != "":
            total = total + 1
    warn = params.get("warn", 10)
    crit = params.get("crit", 20)
    state = "CRIT" if total >= crit else ("WARN" if total >= warn else "OK")
    msg = "Notifications: %d" % total
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"notify_count": total},
            "details": "",
        },
    }