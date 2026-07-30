def _coerce_int(v):
    if v == None:
        return 0
    t = type(v)
    if t == "int":
        return v
    if t == "float":
        return int(v)
    return 0


def main(ctx, params):
    if params.get("_discover"):
        ver = ctx.run(["podman", "--version"], mutates=False, ok_codes=[0, 127])
        if ver.rc == 127:
            return {"changed": False, "msg": "podman not installed", "data": {"discovery": []}}

        res = ctx.run(
            ["podman", "stats", "--no-stream", "--format", "json"],
            mutates=False,
            ok_codes=[0, 1, 125],
        )
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 containers", "data": {"discovery": []}}

        raw = res.stdout.strip()
        if raw == "null" or raw == "[]":
            return {"changed": False, "msg": "discovered 0 containers", "data": {"discovery": []}}

        stats_list = json.decode(raw)
        if not stats_list:
            return {"changed": False, "msg": "discovered 0 containers", "data": {"discovery": []}}

        out = []
        for c in stats_list:
            if c == None:
                continue
            mem_limit = _coerce_int(c.get("MemLimit", 0))
            if mem_limit > 0:
                name = c.get("Name", "")
                if name:
                    out.append({
                        "item": name,
                        "params": {"levels": (150.0, 200.0)},
                        "metrics": ["mem_used", "mem_used_percent"],
                    })

        return {
            "changed": False,
            "msg": "discovered %d containers" % len(out),
            "data": {"discovery": out},
        }

    # Check mode
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no container specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    levels = params.get("levels", (150.0, 200.0))
    warn_perc = levels[0]
    crit_perc = levels[1]

    ver = ctx.run(["podman", "--version"], mutates=False, ok_codes=[0, 127])
    if ver.rc == 127:
        return {
            "changed": False,
            "msg": "podman not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(
        ["podman", "stats", "--no-stream", "--format", "json", item],
        mutates=False,
        ok_codes=[0, 1, 125],
    )
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "container not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = res.stdout.strip()
    if raw == "null" or raw == "[]":
        return {
            "changed": False,
            "msg": "container not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    stats_list = json.decode(raw)
    if not stats_list:
        return {
            "changed": False,
            "msg": "no stats for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    c = stats_list[0]
    if c == None:
        return {
            "changed": False,
            "msg": "null stats entry for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    mem_used = _coerce_int(c.get("MemUsage", 0))
    mem_limit = _coerce_int(c.get("MemLimit", 0))

    if mem_limit == 0:
        return {
            "changed": False,
            "msg": "no memory limit for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    used_perc = 100.0 * mem_used / mem_limit

    state = "CRIT" if used_perc >= crit_perc else ("WARN" if used_perc >= warn_perc else "OK")

    msg = "Used: %f%% - %d of %d bytes" % (used_perc, mem_used, mem_limit)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"mem_used": mem_used, "mem_used_percent": used_perc},
            "details": "",
        },
    }