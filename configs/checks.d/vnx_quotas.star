def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["uemcli", "-h"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "uemcli not available, no VNX quotas", "data": {"discovery": []}}

        fs_res = ctx.run(["uemcli", "-h", "-ssl", "-x", "show", "-type", "LUN", "-o", "-noHeader"], mutates=False)
        if fs_res.rc != 0:
            return {"changed": False, "msg": "could not list VNX filesystems", "data": {"discovery": []}}

        quota_res = ctx.run(["uemcli", "-h", "-ssl", "-x", "show", "-type", "FS_QUOTA", "-o", "-noHeader"], mutates=False)
        if quota_res.rc != 0:
            return {"changed": False, "msg": "could not list VNX quotas", "data": {"discovery": []}}

        fs_sizes = {}
        for line in fs_res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 5:
                fs_name = parts[0]
                val = parts[4]
                fs_sizes[fs_name] = int(val) * 1024 if val.lstrip("-").isdigit() else 0

        quotas = []
        for line in quota_res.stdout.splitlines():
            parts = line.split()
            if len(parts) == 5:
                dms, fs, mp, used_str, limit_str = parts
                quotas.append({
                    "name": dms.strip() + " " + mp.strip(),
                    "fs": fs.strip(),
                    "limit": limit_str,
                    "used": int(used_str) * 1024 if used_str.lstrip("-").isdigit() else 0,
                })

        out = []
        for q in quotas:
            out.append({
                "item": q["name"],
                "params": {"pattern": q["name"]},
                "metrics": ["used_percent"],
            })
        return {"changed": False, "msg": "discovered %d quotas" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    pattern = params.get("pattern", item)

    res = ctx.run(["uemcli", "-h", "-ssl", "-x", "show", "-type", "FS_QUOTA", "-o", "-noHeader"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "could not read VNX quotas", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fs_res = ctx.run(["uemcli", "-h", "-ssl", "-x", "show", "-type", "LUN", "-o", "-noHeader"], mutates=False)
    if fs_res.rc != 0:
        return {"changed": False, "msg": "could not read VNX filesystems", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fs_sizes = {}
    for line in fs_res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 5:
            fs_name = parts[0]
            val = parts[4]
            fs_sizes[fs_name] = int(val) * 1024 if val.lstrip("-").isdigit() else 0

    quota = None
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) == 5:
            dms, fs, mp, used_str, limit_str = parts
            name = dms.strip() + " " + mp.strip()
            if name in (item, pattern):
                quota = {
                    "name": name,
                    "fs": fs.strip(),
                    "limit": limit_str,
                    "used": int(used_str) * 1024 if used_str.lstrip("-").isdigit() else 0,
                }
                break

    if quota == None:
        return {"changed": False, "msg": "no VNX quota found for item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    _MEGA = 1024.0 * 1024.0
    use_fs = quota["limit"] in ("0", "NoLimit") and quota["fs"] in fs_sizes
    size_mb = fs_sizes[quota["fs"]] / _MEGA if use_fs else int(quota["limit"]) / 1024.0
    available_mb = size_mb - quota["used"] / _MEGA
    used_percent = (quota["used"] / _MEGA) / size_mb * 100.0 if size_mb > 0 else 0

    warn = params.get("levels", (80, 90))[0]
    crit = params.get("levels", (80, 90))[1]

    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "VNX Quota %s %d%% used" % (item, int(used_percent))
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"used_percent": used_percent, "size_mb": size_mb, "used_mb": quota["used"] / _MEGA, "avail_mb": available_mb}, "details": ""}}