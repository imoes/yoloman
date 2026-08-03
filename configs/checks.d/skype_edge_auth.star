def _upper(levels):
    if not levels:
        return None
    return levels.get("upper")

def _grade_upper(value, levels):
    if levels == None:
        return "OK"
    u = levels.get("upper")
    if u == None:
        return "OK"
    warn = u[0]
    crit = u[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

# Windows Skype Edge Auth checks use WMI perf counters; no on-host source via ctx here.
# Discovery: requires WMI tables LS:A/V Auth - Requests to exist.
def main(ctx, params):
    if params.get("_discover"):
        # Probe for the WMI table presence via typeperf (Windows perf counters accessible on-host).
        res = ctx.run(["typeperf", "LS:A/V Auth - Requests\\- Bad Requests Received/sec"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no Skype A/V Auth - Requests table", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "LS:A/V Auth - Requests", "params": {"bad_requests": {"upper": (20, 40)}}, "metrics": ["avauth_failed_requests"]}]}}
    item = params.get("item", "LS:A/V Auth - Requests")
    res = ctx.run(["typeperf", "LS:A/V Auth - Requests\\- Bad Requests Received/sec"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no Skype A/V Auth - Requests data", "data": {"state": "UNKNOWN", "metrics": {}, "details": "WMI table LS:A/V Auth - Requests not available"}}
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "no Skype A/V Auth - Requests data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # typeperf output: "timestamp,value"
    last = lines[-1].strip()
    parts = last.split(",")
    if len(parts) < 2 or not parts[1].strip().isdigit():
        return {"changed": False, "msg": "no Skype A/V Auth - Requests data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value = int(parts[1].strip())
    levels = params.get("bad_requests", {"upper": (20, 40)})
    state = _grade_upper(float(value), levels)
    return {"changed": False, "msg": "Bad requests/sec: %s (state %s)" % (str(value), state), "data": {"state": state, "metrics": {"avauth_failed_requests": float(value)}, "details": ""}}