def main(ctx, params):
    MEGA = 1048576.0

    if params.get("_discover"):
        mounts = _discover_cifs_mounts(ctx)
        discovery = []
        for m in mounts:
            discovery.append({
                "item": m["mountpoint"],
                "params": _default_params(),
                "metrics": ["fs_used", "fs_used_percent", "fs_free", "fs_size"],
            })
        n = len(discovery)
        return {
            "changed": False,
            "msg": "discovered %d CIFS mounts" % n,
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    return _check_one_mount(ctx, item, params, MEGA)


def _default_params():
    return {
        "warn": 80,
        "crit": 90,
        "has_perfdata": False,
    }


def _discover_cifs_mounts(ctx):
    res = ctx.run(["mount"], mutates=False)
    if res.rc != 0:
        return []

    mounts = []
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        fstype = ""
        for p in parts:
            if p == "type":
                idx = parts.index(p)
                if idx + 1 < len(parts):
                    fstype = parts[idx + 1]
                break
        if fstype != "cifs":
            continue
        if " on " not in line:
            continue
        after_on = line.split(" on ", 1)[1]
        if " type " in after_on:
            mountpoint = after_on.split(" type ", 1)[0]
        else:
            mountpoint = after_on
        if not mountpoint:
            continue
        mounts.append({"mountpoint": mountpoint})
    return mounts


def _parse_int_field(s):
    val = s.strip()
    return int(val) if val.isdigit() else 0


def _check_one_mount(ctx, item, params, MEGA):
    mount_res = ctx.run(["mount"], mutates=False)
    if mount_res.rc != 0:
        return {
            "changed": False,
            "msg": "no CIFS mount found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    mountpoint = None
    for line in mount_res.stdout.splitlines():
        if " on " not in line:
            continue
        parts = line.split()
        fstype = ""
        for p in parts:
            if p == "type":
                idx = parts.index(p)
                if idx + 1 < len(parts):
                    fstype = parts[idx + 1]
                break
        if fstype != "cifs":
            continue
        after_on = line.split(" on ", 1)[1]
        mp = after_on.split(" type ", 1)[0] if " type " in after_on else after_on
        if mp == item:
            mountpoint = mp
            break

    if mountpoint == None:
        return {
            "changed": False,
            "msg": "no such CIFS mount: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    df_res = ctx.run(["df", "-m", "-P", item], mutates=False)
    if df_res.rc != 0:
        return {
            "changed": False,
            "msg": "unable to stat mount: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lines = df_res.stdout.splitlines()
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "unable to stat mount: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    fields = lines[1].split()
    if len(fields) < 6:
        return {
            "changed": False,
            "msg": "unable to parse df output: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    size_mb = _parse_int_field(fields[1])
    free_mb = _parse_int_field(fields[3])
    used_str = fields[4].rstrip("%")
    used_pct = _parse_int_field(used_str)

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)

    if used_pct >= crit:
        state = "CRIT"
    elif used_pct >= warn:
        state = "WARN"
    else:
        state = "OK"

    used_mb = size_mb - free_mb
    metrics = {
        "fs_used": used_mb,
        "fs_free": free_mb,
        "fs_size": size_mb,
        "fs_used_percent": used_pct,
    }

    summary = "%s %d%% used (%fMB used, %fMB total)" % (item, used_pct, used_mb, size_mb)
    details = "Mountpoint: %s\nFilesystem size: %f MB\nUsed: %f MB (%f%%)\nFree: %f MB" % (
        item, size_mb, used_mb, used_pct, free_mb
    )

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": metrics, "details": details},
    }