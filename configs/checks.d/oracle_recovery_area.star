def main(ctx, params):
    levels = params.get("levels", (70.0, 90.0))
    warn = levels[0]
    crit = levels[1]

    def _format_bytes(mb):
        bytes_val = mb * 1024 * 1024
        units = ["B", "KB", "MB", "GB", "TB", "PB"]
        size = float(bytes_val)
        idx = 0
        while size >= 1024 and idx < len(units) - 1:
            size = size / 1024
            idx = idx + 1
        s = "%f" % size
        return s + " " + units[idx]

    res = ctx.run(["ps", "-e", "-o", "comm="], mutates=False)

    oracle_present = False
    for p in res.stdout.splitlines():
        if p.strip() == "ora_pmon" or p.strip().startswith("ora_pmon_"):
            oracle_present = True
            break

    if not oracle_present:
        return {"changed": False, "msg": "no Oracle instance found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        sql = "set heading off\nset feedback off\nset pagesize 0\nset trimspool on\nselect sid, round((space_limit - space_used) / 1024 / 1024, 0), round(space_used / 1024 / 1024, 0), round(space_reclaimable / 1024 / 1024, 0) from v$recovery_file_dest;\nexit\n"
        res3 = ctx.run(["sqlplus", "-s", "/nolog"], mutates=False)
        if res3.rc != 0:
            return {"changed": False, "msg": "cannot query Oracle",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": "sqlplus failed"}}
        section = []
        for l in res3.stdout.splitlines():
            f = l.split()
            if len(f) >= 5 and f[0] != "SID":
                section.append(f)
        out = []
        for line in section:
            if len(line) < 5:
                continue
            sid = line[0]
            out.append({"item": sid,
                        "params": {"levels": (warn, crit)},
                        "metrics": ["used", "reclaimable"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    sql = "set heading off\nset feedback off\nset pagesize 0\nset trimspool on\nselect sid, round((space_limit - space_used) / 1024 / 1024, 0), round(space_used / 1024 / 1024, 0), round(space_reclaimable / 1024 / 1024, 0) from v$recovery_file_dest;\nexit\n"
    res4 = ctx.run(["sqlplus", "-s", "/nolog"], mutates=False)
    if res4.rc != 0:
        return {"changed": False, "msg": "cannot query Oracle",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "sqlplus failed"}}

    section = []
    for l in res4.stdout.splitlines():
        f = l.split()
        if len(f) >= 5 and f[0] != "SID":
            section.append(f)

    found = None
    for line in section:
        if len(line) < 5:
            continue
        if line[0] == item:
            found = line
            break

    if found == None:
        return {"changed": False, "msg": "login into database failed (no data)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    size_mb = int(found[2])
    used_mb = int(found[3])
    reclaimable_mb = int(found[4])
    if size_mb == 0:
        perc_used = 0.0
    else:
        perc_used = float(used_mb - reclaimable_mb) / size_mb * 100

    warn_mb = size_mb * warn / 100
    crit_mb = size_mb * crit / 100

    if perc_used >= crit:
        state = "CRIT"
    elif perc_used >= warn:
        state = "WARN"
    else:
        state = "OK"

    summary = "%s out of %s used (%f%%, warn/crit at %s%%/%s%%), %s reclaimable" % (
        _format_bytes(used_mb),
        _format_bytes(size_mb),
        perc_used,
        warn,
        crit,
        _format_bytes(reclaimable_mb),
    )
    return {"changed": False, "msg": summary,
            "data": {"state": state,
                     "metrics": {"used": used_mb, "reclaimable": reclaimable_mb,
                                 "used_percent": perc_used},
                     "details": ""}}