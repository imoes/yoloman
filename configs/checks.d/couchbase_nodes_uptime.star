def _format_uptime(seconds):
    days = seconds // 86400
    rem = seconds % 86400
    hours = rem // 3600
    rem2 = rem % 3600
    minutes = rem2 // 60
    if days > 0:
        return "%d days %d hours" % (days, hours)
    if hours > 0:
        return "%d hours %d minutes" % (hours, minutes)
    return "%d minutes" % minutes

def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 8091)
    user = params.get("user", "Administrator")
    password = params.get("password", "")

    url = "http://" + host + ":" + str(port) + "/pools/nodes"
    res = ctx.run(["curl", "-s", "-u", user + ":" + password, url], mutates=False)

    if params.get("_discover"):
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "failed to reach Couchbase API",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        nodes = data.get("nodes", [])
        items = []
        for node in nodes:
            otp_node = node.get("otpNode", "")
            if otp_node:
                items.append({
                    "item": otp_node,
                    "params": {},
                    "metrics": ["uptime"],
                })
        return {"changed": False, "msg": "discovered %d nodes" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")

    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "failed to reach Couchbase API",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)
    nodes = data.get("nodes", [])
    uptime_secs = None

    for node in nodes:
        if node.get("otpNode", "") == item:
            uptime_raw = node.get("uptime", "")
            if uptime_raw:
                int_part = uptime_raw.split(".")[0]
                if int_part.isdigit():
                    uptime_secs = int(int_part)
            break

    if uptime_secs == None:
        return {"changed": False, "msg": "node not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"

    max_levels = params.get("max", None)
    if max_levels != None:
        max_warn = max_levels[0]
        max_crit = max_levels[1]
        if uptime_secs >= max_crit:
            state = "CRIT"
        elif uptime_secs >= max_warn:
            state = "WARN"

    min_levels = params.get("min", None)
    if min_levels != None and state == "OK":
        min_warn = min_levels[0]
        min_crit = min_levels[1]
        if uptime_secs <= min_crit:
            state = "CRIT"
        elif uptime_secs <= min_warn:
            state = "WARN"

    uptime_fmt = _format_uptime(uptime_secs)

    return {
        "changed": False,
        "msg": "Up %s" % uptime_fmt,
        "data": {
            "state": state,
            "metrics": {"uptime": uptime_secs},
            "details": "",
        },
    }