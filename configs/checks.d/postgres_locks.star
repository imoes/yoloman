def _parse_dbs(out):
    sections = {}
    current = None
    cur_db = None
    i = 0
    lines = out.splitlines()
    n = len(lines)
    while i < n:
        line = lines[i]
        i += 1
        if line == "[databases_start]":
            in_db = True
            continue
        if line == "[databases_end]":
            in_db = False
            continue
        if line.startswith("[[[") and line.endswith("]]]"):
            db = line[3:-3]
            current = db
            sections.setdefault(db, [])
            cur_db = db
            continue
        if current == cur_db:
            sections.setdefault(cur_db, [])
            continue
        stripped = line.strip()
        if stripped == "":
            continue
        if ";" not in stripped:
            continue
        parts = stripped.split(";")
        if len(parts) >= 3:
            mode = parts[2]
        granted = parts[1]
        sections.setdefault(current, []).append({"granted": granted, "mode": mode})
    return sections


def _get_locks(ctx, db):
    cmd = ctx.run(
        ["psql", "-t", "-A", "-d", db, "-c",
         "SELECT granted, mode FROM pg_locks WHERE granted ORDER BY mode"],
        mutates=False)
    if cmd.rc != 0:
        return None
    return cmd.stdout


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["psql", "--version"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "psql not found (rc=%d)" % res.rc,
                    "data": {"discovery": [], "host_labels": {}}}
        db_res = ctx.run(
            ["psql", "-t", "-A", "-d", "postgres", "-c",
             "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1"],
            mutates=False)
        if db_res.rc != 0:
            return {"changed": False, "msg": "cannot list databases: %s" % db_res.stderr.strip(),
                    "data": {"discovery": [], "host_labels": {}}}
        dbs = []
        for l in db_res.stdout.splitlines():
            l = l.strip()
            if l == "":
                continue
            dbs.append(l)
        discovery = []
        for db in dbs:
            discovery.append({"item": db, "params": {},
                              "metrics": ["shared_locks", "exclusive_locks"]})
        return {"changed": False, "msg": "discovered %d postgres databases" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {"cmk/postgres": "yes"}}}

    db = params.get("item", "")
    out = _get_locks(ctx, db)
    if out == None:
        return {"changed": False, "msg": "Login into database failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    locks = {}
    for line in out.splitlines():
        line = line.strip()
        if line == "":
            continue
        parts = line.split("|")
        if len(parts) < 2:
            continue
        granted = parts[0]
        mode = parts[1]
        if granted == "t":
            locks.setdefault(mode, 0)
            locks[mode] = locks[mode] + 1

    shared_locks = locks.get("AccessShareLock", 0)
    exclusive_locks = locks.get("ExclusiveLock", 0)

    state = "OK"
    summaries = ["Access Share Locks %d" % shared_locks,
                 "Exclusive Locks %d" % exclusive_locks]

    ls = params.get("levels_shared")
    if ls != None:
        warn_s, crit_s = ls[0], ls[1]
        if shared_locks >= crit_s:
            state = "CRIT"
            summaries.append("shared too high (Levels at %s/%s)" % (warn_s, crit_s))
        elif shared_locks >= warn_s:
            state = "WARN"
            summaries.append("shared too high (Levels at %s/%s)" % (warn_s, crit_s))

    le = params.get("levels_exclusive")
    if le != None:
        warn_e, crit_e = le[0], le[1]
        if exclusive_locks >= crit_e:
            state = "CRIT"
            summaries.append("exclusive too high (Levels at %s/%s)" % (warn_e, crit_e))
        elif exclusive_locks >= warn_e:
            state = "WARN"
            summaries.append("exclusive too high (Levels at %s/%s)" % (warn_e, crit_e))

    return {"changed": False,
            "msg": ", ".join(summaries),
            "data": {"state": state,
                     "metrics": {"shared_locks": shared_locks, "exclusive_locks": exclusive_locks},
                     "details": ""}}