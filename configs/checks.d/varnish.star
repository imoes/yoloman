# Varnish Uptime check plugin for Checkmk
# Reads 'varnishstats' output and reports uptime

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["varnishstats", "-1"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Check if uptime key exists in output
        has_uptime = False
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 3)
            if len(parts) >= 1 and parts[0] == "uptime":
                has_uptime = True
                break
        
        if has_uptime:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": ["uptime"]}]}}

        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    # Check mode
    res = ctx.run(["varnishstats", "-1"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "could not execute varnishstats",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    uptime_sec = None
    for line in res.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) >= 1 and parts[0] == "uptime":
            if len(parts) >= 2 and parts[1].isdigit():
                uptime_sec = int(parts[1])
            break

    if uptime_sec == None:
        return {"changed": False, "msg": "uptime value not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Compute human-readable uptime
    total_seconds = uptime_sec
    days = total_seconds // 86400
    hours = (total_seconds % 86400) // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = total_seconds % 60

    uptime_str = "%d days %d hours %d minutes %d seconds" % (days, hours, minutes, seconds)

    return {"changed": False, "msg": "Uptime: " + uptime_str,
            "data": {"state": "OK", "metrics": {"uptime": uptime_sec}, "details": ""}}
