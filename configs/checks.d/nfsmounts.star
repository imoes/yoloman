NFS_FSTYPES = ["nfs", "nfs4"]

def main(ctx, params):
    if params.get("_discover"):
        if not ctx.file_exists("/proc/mounts"):
            return {
                "changed": False,
                "msg": "discovered 0 NFS mounts",
                "data": {"discovery": []},
            }
        content = ctx.file_read("/proc/mounts")
        mounts = []
        for line in content.splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            if parts[2] in NFS_FSTYPES:
                mounts.append({
                    "item": parts[1],
                    "params": {"warn": 80.0, "crit": 90.0},
                    "metrics": ["used_percent", "fs_used", "fs_free", "fs_size"],
                })
        return {
            "changed": False,
            "msg": "discovered %d NFS mounts" % len(mounts),
            "data": {"discovery": mounts},
        }

    item = params.get("item", "")
    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)

    if not ctx.file_exists("/proc/mounts"):
        return {
            "changed": False,
            "msg": "cannot read /proc/mounts",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    content = ctx.file_read("/proc/mounts")
    source = None
    for line in content.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == item and parts[2] in NFS_FSTYPES:
            source = parts[0]
            break

    if source == None:
        return {
            "changed": False,
            "msg": "NFS mount not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(["df", "-Pk", item], mutates=False, ok_codes=[0, 1])

    if res.rc != 0:
        if "Permission denied" in res.stderr or "Permission denied" in res.stdout:
            return {
                "changed": False,
                "msg": "State: Permission denied - " + item,
                "data": {"state": "CRIT", "metrics": {}, "details": res.stderr},
            }
        return {
            "changed": False,
            "msg": "State: Hanging - " + item,
            "data": {"state": "CRIT", "metrics": {}, "details": res.stderr},
        }

    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "Source: %s - Mount seems OK" % source,
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    fields = lines[1].split()
    if len(fields) < 6:
        return {
            "changed": False,
            "msg": "unexpected df output for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total_kb = int(fields[1]) if fields[1].isdigit() else 0
    used_kb = int(fields[2]) if fields[2].isdigit() else 0
    avail_kb = int(fields[3]) if fields[3].isdigit() else 0

    if total_kb <= 0:
        return {
            "changed": False,
            "msg": "Stale fs handle: " + item,
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }

    used_percent = (used_kb * 100.0) / total_kb
    total_mb = total_kb / 1024.0
    used_mb = used_kb / 1024.0
    free_mb = avail_kb / 1024.0

    state = "CRIT" if used_percent >= crit else ("WARN" if used_percent >= warn else "OK")
    msg = "Source: %s - Used: %f%% (%f of %f MB)" % (source, used_percent, used_mb, total_mb)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "fs_used": used_mb,
                "fs_free": free_mb,
                "fs_size": total_mb,
            },
            "details": "",
        },
    }