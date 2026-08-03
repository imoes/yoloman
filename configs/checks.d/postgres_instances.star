def _running_postgres_instances(ctx):
    res = ctx.run(["ps", "-eo", "pid,comm,args"], mutates=False)
    if res.rc != 0:
        return []
    instances = []
    seen = set()
    for line in res.stdout.splitlines()[1:]:
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid_s, comm, args = parts[0], parts[1], parts[2]
        if not comm.endswith("-postgres"):
            continue
        if not pid_s.lstrip("-").isdigit():
            continue
        data_dir = ""
        idx = args.find(" -D ")
        if idx >= 0:
            rest = args[idx + 4:]
            sp = rest.find(" ")
            data_dir = rest if sp < 0 else rest[:sp]
        if not data_dir:
            continue
        name = data_dir.split("/")[-1].upper()
        if name == "" or name in seen:
            continue
        seen.add(name)
        instances.append({"name": name, "pid": int(pid_s)})
    return instances


def _postgres_version(ctx):
    for path in ["/usr/lib/postgresql", "/usr/pgsql"]:
        st = ctx.stat(path)
        if st and st.get("is_dir"):
            res = ctx.run(["ls", "-1", path], mutates=False)
            if res.rc == 0:
                best = ""
                for line in res.stdout.splitlines():
                    cand = line.strip()
                    if cand and cand > best:
                        best = cand
                if best:
                    ver = best.split("/")[-1].split(".")
                    short = ver[0] + "." + ver[1] if len(ver) > 1 else ver[0]
                    return "PostgreSQL " + short
    bin_res = ctx.run(["postgres", "--version"], mutates=False)
    if bin_res.rc == 0:
        out = bin_res.stdout.strip()
        if out:
            return out
    return None


def main(ctx, params):
    if params.get("_discover"):
        pg_res = ctx.run(["postgres", "--version"], mutates=False)
        if pg_res.rc == 127:
            return {"changed": False, "msg": "no postgres found",
                    "data": {"discovery": []}}
        instances = _running_postgres_instances(ctx)
        out = []
        for inst in instances:
            out.append({"item": inst["name"], "params": {},
                        "metrics": []})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    instances = _running_postgres_instances(ctx)
    matched = None
    for inst in instances:
        if inst["name"] == item.upper():
            matched = inst
            break

    if matched == None:
        return {"changed": False,
                "msg": "No postgres instance found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    version_info = _postgres_version(ctx)

    if version_info != None:
        msg = "Status: running with PID " + str(matched["pid"]) + ", Version: " + version_info
    else:
        msg = "Status: running with PID " + str(matched["pid"]) + ", Version: not found"

    return {"changed": False, "msg": msg,
            "data": {"state": "OK", "metrics": {},
                     "details": "PID: " + str(matched["pid"])}}