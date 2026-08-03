def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/sys/fs/file-nr"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "not applicable",
                    "data": {"discovery": []}}
        parts = res.stdout.split()
        if len(parts) < 3:
            return {"changed": False, "msg": "not applicable",
                    "data": {"discovery": []}}
        allocated = parts[0]
        maximum = parts[2]
        if not allocated.isdigit() or not maximum.isdigit():
            return {"changed": False, "msg": "not applicable",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": [80.0, 90.0]},
                     "metrics": ["filehandler_perc"]}
                ]}}
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/sys/fs/file-nr"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot read /proc/sys/fs/file-nr",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parts = res.stdout.split()
    if len(parts) < 3:
        return {"changed": False, "msg": "unexpected file-nr output: " + res.stdout,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    allocated_s = parts[0]
    maximum_s = parts[2]
    if not allocated_s.isdigit() or not maximum_s.isdigit():
        return {"changed": False, "msg": "non-numeric file-nr output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    allocated = int(allocated_s)
    maximum = int(maximum_s)
    if maximum == 0:
        return {"changed": False, "msg": "maximum file handles is zero",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    perc = float(allocated) / float(maximum) * 100.0
    levels = params.get("levels", [80.0, 90.0])
    warn = levels[0] if len(levels) > 0 else 80.0
    crit = levels[1] if len(levels) > 1 else 90.0
    state = "CRIT" if perc >= crit else ("WARN" if perc >= warn else "OK")
    return {"changed": False,
            "msg": "(%d of %d file handles)" % (allocated, maximum),
            "data": {"state": state, "metrics": {"filehandler_perc": perc}, "details": ""}}