def main(ctx, params):
    if params.get("_discover"):
        path = "/var/lib/oracle_recovery_area.txt"
        if not ctx.file_exists(path):
            return {
                "changed": False,
                "msg": "discovered 0 recovery areas",
                "data": {"discovery": []},
            }
        content = ctx.file_read(path)
        items = []
        for line in content.strip().split("\n"):
            parts = line.strip().split()
            if len(parts) >= 5 and parts[0] != "":
                sid = parts[0]
                items.append({
                    "item": sid,
                    "params": {"levels": (70.0, 90.0)},
                    "metrics": ["used", "reclaimable"],
                })
        return {
            "changed": False,
            "msg": "discovered %d recovery areas" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    levels = params.get("levels", (70.0, 90.0))
    warn_pct = float(levels[0])
    crit_pct = float(levels[1])

    path = "/var/lib/oracle_recovery_area.txt"
    if not ctx.file_exists(path):
        return {
            "changed": False,
            "msg": "data file missing: " + path,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    content = ctx.file_read(path)
    data_found = False
    size_mb = 0
    used_mb = 0
    reclaimable_mb = 0

    for line in content.strip().split("\n"):
        parts = line.strip().split()
        if len(parts) < 5:
            continue
        if parts[0] == item:
            data_found = True
            used_str = parts[3]
            size_str = parts[2]
            reclaim_str = parts[4]
            if not used_str.isdigit() or not size_str.isdigit() or not reclaim_str.isdigit():
                return {
                    "changed": False,
                    "msg": "invalid data for " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            used_mb = int(used_str)
            size_mb = int(size_str)
            reclaimable_mb = int(reclaim_str)
            break

    if not data_found:
        return {
            "changed": False,
            "msg": "no data for recovery area: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if size_mb == 0:
        perc_used = 0.0
    else:
        perc_used = (float(used_mb - reclaimable_mb) / size_mb) * 100.0

    warn_mb = size_mb * warn_pct / 100.0
    crit_mb = size_mb * crit_pct / 100.0

    state = "CRIT"
    if perc_used >= crit_pct:
        state = "CRIT"
    elif perc_used >= warn_pct:
        state = "WARN"
    else:
        state = "OK"

    summary = "%d out of %d MB used (%f%%, warn/crit at %f%%/%f%%), %d MB reclaimable" % (
        used_mb,
        size_mb,
        perc_used,
        warn_pct,
        crit_pct,
        reclaimable_mb,
    )

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "used": float(used_mb),
                "reclaimable": float(reclaimable_mb),
            },
            "details": "",
        },
    }