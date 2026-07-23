def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/yolo-man/agent/output/fritz"], mutates=False)
        section = {}
        for line in res.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) > 1:
                section[parts[0]] = parts[1]
        
        conn_stat = section.get("NewConnectionStatus")
        if conn_stat and conn_stat != "Unconfigured" and "NewExternalIPAddress" in section:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
            }
        return {
            "changed": False,
            "msg": "discovered 0 services",
            "data": {"discovery": []}
        }

    res = ctx.run(["cat", "/var/lib/yolo-man/agent/output/fritz"], mutates=False)
    section = {}
    for line in res.stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) > 1:
            section[parts[0]] = parts[1]

    conn_stat = section.get("NewConnectionStatus")
    
    if conn_stat == "Connected":
        state = "OK"
        summary = "Connection status: Connected"
        if "NewExternalIPAddress" in section:
            summary += ", WAN IP Address: " + section["NewExternalIPAddress"]
        details = ""
    elif conn_stat in ("Connected", "Connecting", "Disconnected", "Unconfigured"):
        state = "WARN"
        summary = "Connection status: " + conn_stat
        details = ""
    elif conn_stat:
        state = "UNKNOWN"
        summary = "Connection status: " + conn_stat
        details = ""
    else:
        state = "UNKNOWN"
        summary = "Connection status: unknown"
        details = ""

    last_err = section.get("NewLastConnectionError")
    if last_err and last_err != "ERROR_NONE":
        summary += ", Last Error: " + last_err

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }
