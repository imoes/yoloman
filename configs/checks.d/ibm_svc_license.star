def _parse_licenses(stdout):
    licenses = {}
    for line in stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        parts = line.split(":")
        if len(parts) < 2:
            continue
        key = parts[0].strip()
        val = parts[1].strip()
        if key.startswith("license_"):
            name = key[8:]
            if name not in licenses:
                licenses[name] = [0.0, 0.0]
            licenses[name][0] = 0.0 if val == "off" else float(val)
        elif key.startswith("used_"):
            name = key[5:]
            if name not in licenses:
                licenses[name] = [0.0, 0.0]
            licenses[name][1] = float(val)
    return licenses


def _compute_levels(licensed, kind, warn_val, crit_val):
    if kind == "always_ok":
        return None, None
    if kind == "crit_on_all":
        return licensed, licensed
    if kind == "absolute":
        w = licensed - warn_val
        c = licensed - crit_val
        return (0.0 if w < 0.0 else w), (0.0 if c < 0.0 else c)
    if kind == "percentage":
        return licensed * (1.0 - warn_val / 100.0), licensed * (1.0 - crit_val / 100.0)
    return None, None


def main(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("user", "monitor")
    port = params.get("port", 22)
    levels_kind = params.get("levels_kind", "crit_on_all")
    levels_warn = params.get("levels_warn", 0.0)
    levels_crit = params.get("levels_crit", 0.0)

    argv = [
        "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
        "-p", str(port), user + "@" + host,
        "lslicense", "-delim", ":",
    ]
    res = ctx.run(argv, mutates=False)

    if res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "ssh lslicense failed: " + res.stderr,
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "ssh lslicense failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr}}

    licenses = _parse_licenses(res.stdout)

    if params.get("_discover"):
        items = []
        for name in sorted(licenses.keys()):
            d = licenses[name]
            if d[0] != 0.0 or d[1] != 0.0:
                items.append({
                    "item": name,
                    "params": {"levels_kind": "crit_on_all"},
                    "metrics": ["licenses"],
                })
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    if item not in licenses:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    licensed = licenses[item][0]
    used = licenses[item][1]

    warn, crit = _compute_levels(licensed, levels_kind, levels_warn, levels_crit)

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
            summary += " (warn/crit at %d/%d)" % (int(warn), int(crit))

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {"licenses": used}, "details": ""},
    }