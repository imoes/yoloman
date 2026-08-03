def _detect_kaspersky(ctx):
    res = ctx.run(["kav_main", "--get-status-info"], mutates=False)
    if res.rc == 127:
        return None
    return res

def _parse_status(stdout):
    section = {}
    for line in stdout.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            section[key.strip()] = value.strip()
    return section

def main(ctx, params):
    if params.get("_discover"):
        res = _detect_kaspersky(ctx)
        if res == None:
            return {"changed": False, "msg": "kaspersky not installed", "data": {"discovery": []}}
        section = _parse_status(res.stdout)
        if section:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {"changed": False, "msg": "no kaspersky data", "data": {"discovery": []}}

    res = _detect_kaspersky(ctx)
    if res == None:
        return {
            "changed": False,
            "msg": "kaspersky not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    section = _parse_status(res.stdout)
    if not section:
        return {
            "changed": False,
            "msg": "no kaspersky status data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    state_val = section.get("Current AV databases state", "")
    state = "CRIT" if state_val != "UpToDate" else "OK"
    summary = "Database State: %s" % state_val
    date_str = section.get("Current AV databases date", "")
    last_update = section.get("Last AV databases update date", "")
    details = "Database Date: %s\nLast Update: %s" % (date_str, last_update)
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": details},
    }