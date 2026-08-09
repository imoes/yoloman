def main(ctx, params):
    if params.get("_discover"):
        section = _gather(ctx, params)
        if section == None:
            return {"changed": False, "msg": "HP ProLiant PSU check not available",
                    "data": {"discovery": []}}
        out = []
        keys = list(section.keys())
        for item in keys:
            metrics = ["power_usage"]
            if item == "Total":
                metrics = []
            out.append({"item": item, "metrics": metrics})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    section = _gather(ctx, params)
    if section == None:
        return {"changed": False, "msg": "HP ProLiant PSU check not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    item = params.get("item", "")
    psu = section.get(item)
    if psu == None:
        return {"changed": False, "msg": "no such PSU: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0]
    crit = levels[1]
    used = psu["used"]
    max_ = psu["max_"]
    pct = (used * 100.0 / max_) if max_ != 0 else 0
    if pct >= crit:
        state = "CRIT"
    elif pct >= warn:
        state = "WARN"
    else:
        state = "OK"
    if item == "Total":
        summary = "Usage: %d/%d Watts" % (used, max_)
        metrics = {}
    else:
        summary = "Chassis %s/Bay %s" % (psu["chassis"], psu["bay"])
        if item + ":cond" + ":other" == "x":  # placeholder
            pass
        cond_summary = _cond_summary(psu["cond"])
        state = _cond_state(psu["cond"])
        if state == "OK":
            state = _level_state(pct, warn, crit)
        metrics = {"power_usage": used}
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _gather(ctx, params):
    base = ".1.3.6.1.4.1.232.6.2.9.3.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c",
                   params.get("community", "public"), "-Oqn",
                   params.get("host", "localhost"), base], mutates=False)
    if res.rc != 0:
        return None
    rows = {}
    oids = ["1", "2", "3", "4", "7", "8"]
    for line in res.stdout.split("\n"):
        if line == "" or line == None:
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        suffix = oid[len(base):]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        col = parts[0]
        idx = ".".join(parts[1:])
        if col in oids:
            rows.setdefault(idx, {"1": "", "2": "", "3": "", "4": "", "7": "", "8": ""})
            rows[idx][col] = val
    section = {}
    total_used = 0
    max_total = 0
    for idx in sorted(rows.keys()):
        r = rows[idx]
        present = r["3"]
        capmax = r["8"]
        if present != "3" or capmax == "0":
            continue
        chassis = r["1"]
        bay = r["2"]
        cond = r["4"]
        used_s = r["7"]
        max_s = capmax
        used = int(used_s) if used_s != "" and used_s != None and used_s.lstrip("-").isdigit() else 0
        max_ = int(max_s) if max_s != "" and max_s != None and max_s.lstrip("-").isdigit() else 0
        item = chassis + "/" + bay
        section[item] = {"chassis": chassis, "bay": bay, "cond": cond,
                         "used": used, "max_": max_}
        total_used += used
        max_total += max_
    if section:
        section["Total"] = {"used": total_used, "max_": max_total}
    return section


_COND_MAP = {
    "1": ("UNKNOWN", 'State: "other"'),
    "2": ("OK", 'State: "ok"'),
    "3": ("CRIT", 'State: "degraded"'),
    "4": ("CRIT", 'State: "failed"'),
}


def _cond_state(cond):
    r = _COND_MAP.get(cond)
    if r == None:
        return "UNKNOWN"
    return r[0]


def _cond_summary(cond):
    r = _COND_MAP.get(cond)
    if r == None:
        return 'State: "unknown"'
    return r[1]


def _level_state(pct, warn, crit):
    if pct >= crit:
        return "CRIT"
    if pct >= warn:
        return "WARN"
    return "OK"