def _parse_tunables(output):
    parsed = {}
    key = ""
    usage = 0
    for line in output.splitlines():
        f = line.split(":")
        if len(f) < 2:
            continue
        label = f[0].strip()
        value = ":".join(f[1:]).strip()
        if "Tunable" in label or "Parameter" in label:
            key = value
        elif "Usage" in label:
            usage = int(value) if value.isdigit() else 0
        elif "Setting" in label:
            threshold = int(value) if value.isdigit() else 0
            if key != "":
                parsed[key] = (usage, threshold)
    return parsed

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["kconfig", "-u"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "kconfig not available", "data": {"discovery": []}}
        parsed = _parse_tunables(res.stdout)
        if "maxfiles_lim" not in parsed:
            return {"changed": False, "msg": "no maxfiles_lim tunable found", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "maxfiles_lim", "params": {"levels": (85.0, 90.0)}, "metrics": ["files"]}
                ]}}
    item = params.get("item", "maxfiles_lim")
    res = ctx.run(["kconfig", "-u"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "kconfig not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = _parse_tunables(res.stdout)
    if item not in parsed:
        return {"changed": False, "msg": "no such tunable: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    usage, threshold = parsed[item]
    if threshold == 0:
        return {"changed": False, "msg": "setting is zero",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    perc = float(usage) / float(threshold) * 100
    levels = params.get("levels", (85.0, 90.0))
    warn = levels[0]
    crit = levels[1]
    warn_perf = float(warn * threshold / 100)
    crit_perf = float(crit * threshold / 100)
    state = "OK"
    if perc > crit:
        state = "CRIT"
    elif perc > warn:
        state = "WARN"
    msg = "%f%% used (%d/%d files)" % (perc, usage, threshold)
    summary = msg
    if state != "OK":
        summary = msg + " (warn/crit at %s/%s)" % (warn, crit)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"files": usage}, "details": ""}}