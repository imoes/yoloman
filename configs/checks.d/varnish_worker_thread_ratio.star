def main(ctx, params):
    # Probe for varnishstat binary first — absence means not installed
    probe = ctx.run(["varnishstat", "-V"], mutates=False)
    if probe.rc != 0:
        return {
            "changed": False,
            "msg": "varnishstat not found (not installed or not running)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no varnishstat binary"},
        }

    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": [], "host_labels": {}}}
        has_n_wrk = False
        has_n_wrk_create = False
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            name = parts[0]
            if name == "n_wrk":
                has_n_wrk = True
            if name == "n_wrk_create":
                has_n_wrk_create = True
        if has_n_wrk and has_n_wrk_create:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {"item": "", "params": {"levels_lower": (70.0, 60.0)}, "metrics": ["varnish_worker_thread_ratio"]}
                    ],
                    "host_labels": {"cmk/os_family": ctx.facts().get("os_family", "unknown")},
                },
            }
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": [], "host_labels": {}}}

    res = ctx.run(["varnishstat", "-1"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no varnishstat output", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0]
        val = parts[1]
        if val.lstrip("-").isdigit():
            stats[name] = int(val)

    if "n_wrk" not in stats or "n_wrk_create" not in stats:
        return {"changed": False, "msg": "missing n_wrk or n_wrk_create in varnishstat output", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    worker_create = stats["n_wrk_create"]
    worker_current = stats["n_wrk"]
    ratio = 0.0
    if worker_create > 0:
        ratio = 100.0 * worker_current / worker_create

    levels = params.get("levels_lower", (70.0, 60.0))
    warn = levels[0]
    crit = levels[1]

    state = "OK"
    if ratio <= crit:
        state = "CRIT"
    elif ratio <= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Worker thread ratio: %f%% (current: %d, created: %d)" % (ratio, worker_current, worker_create),
        "data": {"state": state, "metrics": {"varnish_worker_thread_ratio": ratio}, "details": "n_wrk=%d, n_wrk_create=%d" % (worker_current, worker_create)},
    }