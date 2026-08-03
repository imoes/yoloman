def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["vgs", "--noheadings", "-o", "vg_name,vg_size,vg_free",
                       "--units", "b", "--nosuffix"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "vgs not found on host",
                    "data": {"discovery": [], "host_labels": {}}}
        out = []
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 3:
                continue
            vg = f[0]
            try_size = _safe_int(f[1])
            try_free = _safe_int(f[2])
            if try_size == None or try_free == None:
                continue
            size_mib = try_size // (1024 * 1024)
            free_mib = try_free // (1024 * 1024)
            used_mib = size_mib - free_mib
            used_percent = 0
            if size_mib > 0:
                used_percent = used_mib * 100 // size_mib
            out.append({
                "item": vg,
                "params": _default_fs_params(),
                "metrics": ["size", "used_percent", "used", "free"],
                "service_labels": {"lvm_vg_name": vg},
            })
        return {"changed": False, "msg": "discovered %d volume groups" % len(out),
                "data": {"discovery": out, "host_labels": {}}}

    item = params.get("item", "")
    res = ctx.run(["vgs", "--noheadings", "-o", "vg_name,vg_size,vg_free",
                   "--units", "b", "--nosuffix", item], mutates=False)
    if res.rc != 0 and res.rc != 127:
        return {"changed": False, "msg": "vgs failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return {"changed": False, "msg": "no such volume group: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    f = lines[0].split()
    if len(f) < 3:
        return {"changed": False, "msg": "cannot parse vg line for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    size_b = _safe_int(f[1])
    free_b = _safe_int(f[2])
    if size_b == None or free_b == None:
        return {"changed": False, "msg": "cannot parse vg sizes for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    size_mib = size_b // (1024 * 1024)
    free_mib = free_b // (1024 * 1024)
    used_mib = size_mib - free_mib
    used_percent = 0
    if size_mib > 0:
        used_percent = used_mib * 100 // size_mib
    state, level = _grade_fs(used_percent, size_mib, params)
    msg = "Size: %d MB, Used: %d%% (%d MB of %d MB), Free: %d MB" % (
        size_mib, used_percent, used_mib, size_mib, free_mib)
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"size": float(size_mib), "used": float(used_mib),
                                 "free": float(free_mib), "used_percent": float(used_percent)},
                     "details": "used_percent=%d level=%s" % (used_percent, level)}}


def _safe_int(s):
    t = s.strip()
    if t == "":
        return None
    neg = False
    if t.startswith("-"):
        neg = True
        t = t[1:]
    if not t.isdigit():
        return None
    v = 0
    for ch in t:
        v = v * 10 + (ord(ch) - ord("0"))
    return -v if neg else v


def _default_fs_params():
    return {"levels": (80, 90), "growth": (10, 100), "show_fs": True, "show_mount": False}


def _grade_fs(used_percent, size_mib, params):
    levels = params.get("levels", (80, 90))
    warn = levels[0]
    crit = levels[1]
    if size_mib <= 0:
        return ("OK", "none")
    if used_percent >= crit:
        return ("CRIT", "crit:%d" % crit)
    if used_percent >= warn:
        return ("WARN", "warn:%d" % warn)
    return ("OK", "ok")