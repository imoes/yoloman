def _compute_levels(licensed, level_spec):
    kind = level_spec[0]
    value = level_spec[1]
    if kind == "always_ok":
        return None, None
    if kind == "crit_on_all":
        return licensed, licensed
    if kind == "absolute":
        warn_abs = value[0]
        crit_abs = value[1]
        return max(0.0, licensed - warn_abs), max(0.0, licensed - crit_abs)
    if kind == "percentage":
        warn_pct = value[0]
        crit_pct = value[1]
        return licensed * (1 - warn_pct / 100.0), licensed * (1 - crit_pct / 100.0)
    return None, None


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["svcinfo", "lslicense"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no ibm_svc_license data available",
                    "data": {"discovery": []}}
        licenses = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or ":" not in line:
                continue
            parts = line.split(":", 1)
            if len(parts) != 2:
                continue
            key = parts[0].strip()
            val = parts[1].strip()
            if key.startswith("license_"):
                license_ = key.replace("license_", "")
                if license_ not in licenses:
                    licenses[license_] = [0.0, 0.0]
                licenses[license_][0] = 0.0 if val == "off" else float(val)
            elif key.startswith("used_"):
                license_ = key.replace("used_", "")
                if license_ not in licenses:
                    licenses[license_] = [0.0, 0.0]
                licenses[license_][1] = float(val)
        section = {}
        for item, data in licenses.items():
            section[item] = (data[0], data[1])
        discovery = []
        for item, data in section.items():
            if data != (0.0, 0.0):
                discovery.append({"item": item, "params": {"levels": ("crit_on_all", None)},
                                  "metrics": ["licenses"]})
        return {"changed": False, "msg": "discovered %d license items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["svcinfo", "lslicense"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "svcinfo lslicense not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    licenses = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        parts = line.split(":", 1)
        if len(parts) != 2:
            continue
        key = parts[0].strip()
        val = parts[1].strip()
        if key.startswith("license_"):
            license_ = key.replace("license_", "")
            if license_ not in licenses:
                licenses[license_] = [0.0, 0.0]
            licenses[license_][0] = 0.0 if val == "off" else float(val)
        elif key.startswith("used_"):
            license_ = key.replace("used_", "")
            if license_ not in licenses:
                licenses[license_] = [0.0, 0.0]
            licenses[license_][1] = float(val)
    section = {}
    for i, data in licenses.items():
        section[i] = (data[0], data[1])
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "no license item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    licensed, used = data
    levels = params.get("levels", ("crit_on_all", None))
    warn, crit = _compute_levels(licensed, levels)
    if used <= licensed:
        summary = "used %d out of %d licenses" % (int(used), int(licensed))
    else:
        summary = "used %d licenses, but you have only %d" % (int(used), int(licensed))
    state = "OK"
    if warn != None and crit != None:
        if used >= crit:
            state = "CRIT"
        elif used >= warn:
            state = "WARN"
        if state != "OK":
            summary = summary + " (warn/crit at %d/%d)" % (int(warn), int(crit))
    metrics = {"licenses": used}
    if warn != None and crit != None:
        metrics = {"licenses": used}
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}