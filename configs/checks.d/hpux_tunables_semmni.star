DEFAULT_SEMMNI_LEVELS = (85.0, 90.0)
SEMMNI_TUNABLE = "semmni"
SEMMNI_DESCR = "semaphore_ids"

def _to_int(value):
    v = value.strip()
    if v.isdigit():
        return int(v)
    v2 = v.strip('"').strip("'")
    return int(v2) if v2.isdigit() else 0

def _parse_kctune(text):
    parsed = {}
    key = ""
    usage = 0
    for raw in text.splitlines():
        line = raw.split()
        if len(line) < 2:
            continue
        head = line[0]
        value = line[1]
        if head in ("Tunable", "Parameter"):
            key = value.strip()
        elif head == "Usage":
            usage = _to_int(value)
        elif head == "Setting":
            threshold = _to_int(value)
            if key != "":
                parsed[key] = (usage, threshold)
    return parsed

def _grade_percentage(perc, levels):
    warn, crit = levels
    if perc >= crit:
        return "CRIT"
    if perc >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["kctune", "-l"], mutates=False)
        if res.rc == 127:
            return {"changed": False,
                    "msg": "discovered 0 hpux tunables (kctune not installed)",
                    "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 hpux tunables",
                    "data": {"discovery": []}}
        section = _parse_kctune(res.stdout)
        out = []
        if SEMMNI_TUNABLE in section:
            out.append({
                "item": SEMMNI_TUNABLE,
                "params": {"levels": list(DEFAULT_SEMMNI_LEVELS)},
                "metrics": [SEMMNI_DESCR],
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item == "":
        item = SEMMNI_TUNABLE

    res = ctx.run(["kctune", "-l"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "kctune not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no hpux tunables available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_kctune(res.stdout)
    if item not in section:
        return {"changed": False, "msg": "tunable %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    usage, threshold = section[item]
    if threshold == 0:
        return {"changed": False, "msg": "tunable %s has setting 0" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    perc = float(usage) / float(threshold) * 100.0
    levels = params.get("levels", DEFAULT_SEMMNI_LEVELS)
    state = _grade_percentage(perc, levels)

    warn_perf = float(levels[0]) * threshold / 100.0
    crit_perf = float(levels[1]) * threshold / 100.0

    msg = "%f%% used (%d/%d %s)" % (perc, usage, threshold, SEMMNI_DESCR)
    if state != "OK":
        msg = msg + " (warn/crit at %f/%f)" % (levels[0], levels[1])

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {SEMMNI_DESCR: usage},
                     "details": "",
                     "levels": {"warn": warn_perf, "crit": crit_perf}}}