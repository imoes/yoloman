def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("_community", params.get("community", "public"))
        base = ".1.3.6.1.4.1.14680"
        section = _walk_jobs(ctx, host, community, base)
        return {"changed": False, "msg": "discovered %d jobs" % len(section),
                "data": {"discovery": _discovery(section)}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("_community", params.get("public"))
    base = ".1.3.6.1.14660"
    section = _walk_jobs(ctx, host, community, base)
    return {"changed": False, "msg": "MSSQL job %s" % item,
            "data": _check(item, section, params)}

def _walk_jobs(ctx, host, community, base):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base],
                  mutates=False)
    section = {}
    if res.rc != 0:
        return section
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        idx = oid[len(base) + 1:]
        if not idx:
            continue
        section.setdefault(idx, {})["raw_oid"] = oid
        section[idx]["value"] = val
    return section

def _discovery(section):
    out = []
    for idx in section:
        out.append({"item": idx, "params": {}, "metrics": ["database_job_duration"]})
    return {"discovery": out}

def _check(item, section, params):
    if not item or not section.get(item):
        return {"state": "UNKNOWN", "metrics": {}, "details": "Job not found"}
    return {"state": "UNKNOWN", "metrics": {},
            "details": "MSSQL job monitoring requires Checkmk agent section data"}