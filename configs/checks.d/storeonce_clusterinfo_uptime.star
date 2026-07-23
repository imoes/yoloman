def _format_uptime(secs):
    days = secs // 86400
    remaining = secs % 86400
    hours = remaining // 3600
    minutes = (remaining % 3600) // 60
    return "%d days %d hours %d minutes" % (days, hours, minutes)

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["uptime"]},
            ]},
        }

    host = params.get("host", "localhost")
    port = params.get("port", 443)
    username = params.get("username", "admin")
    password = params.get("password", "")

    url = "https://%s:%d/rest/storeonce/management-directory/properties" % (host, port)

    res = ctx.run([
        "curl", "-s", "-k",
        "-u", "%s:%s" % (username, password),
        "-H", "Accept: application/json",
        url,
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "API request failed: " + res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    stdout = res.stdout.strip()
    if not stdout:
        return {
            "changed": False,
            "msg": "empty response from StoreOnce API",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = json.decode(stdout)
    raw = data.get("uptimeSeconds")
    if raw == None:
        return {
            "changed": False,
            "msg": "uptimeSeconds field missing in API response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    uptime_secs = int(float(str(raw)))
    summary = "Uptime: " + _format_uptime(uptime_secs)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {"uptime": uptime_secs},
            "details": "",
        },
    }