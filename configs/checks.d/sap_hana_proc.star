def main(ctx, params):
    base = ctx.run(["ls", "-d", "/hana"], mutates=False)
    if base.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no SAP HANA found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "SAP HANA not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        res = ctx.run(["ps", "-eo", "user,pid,ppid,comm,args"], mutates=False)
        hosts = []
        seen = {}
        for line in res.stdout.splitlines()[1:]:
            parts = line.split(None, 4)
            if len(parts) < 5:
                continue
            args = parts[4]
            if args.find("hdb") == -1 and args.find("indexserver") == -1:
                continue
            tokens = args.split()
            inst = ""
            for t in tokens:
                if t.endswith(".py") or t.endswith(".so"):
                    continue
                if t.startswith("/hana/"):
                    seg = t.split("/")
                    if len(seg) > 4:
                        inst = seg[3]
                        break
            if inst == "":
                continue
            if inst in seen:
                continue
            seen[inst] = True
            hosts.append({"item": inst, "params": {"coordin": "none"},
                          "metrics": []})
        return {"changed": False,
                "msg": "discovered %d SAP HANA processes" % len(hosts),
                "data": {"discovery": hosts}}

    item = params.get("item", "")
    ps_res = ctx.run(["ps", "-eo", "user,pid,ppid,comm,args"], mutates=False)
    found = None
    for line in ps_res.stdout.splitlines()[1:]:
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        args = parts[4]
        if args.find("hdb") == -1 and args.find("indexserver") == -1:
            continue
        tokens = args.split()
        inst = ""
        for t in tokens:
            if t.endswith(".py") or t.endswith(".so"):
                continue
            if t.startswith("/hana/"):
                seg = t.split("/")
                if len(seg) > 4:
                    inst = seg[3]
                    break
        if inst == item:
            found = {"pid": parts[1]}
            break

    if found == None:
        return {"changed": False,
                "msg": "no SAP HANA process for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ini = ctx.run(["grep", "-rl", "coordinator", "/hana"], mutates=False)
    coordin = "none"
    if ini.rc == 0:
        for line in ini.stdout.splitlines():
            if line.find(item) != -1:
                coordin = "coordinator"
                break
    pid = found["pid"]
    acting = "yes"
    if coordin.lower() != "none":
        acting = "yes"
    state = "OK"
    if acting.lower() != "yes":
        state = "CRIT"
    summaries = []
    summaries.append("Port: 30015, PID: %s" % pid)
    summaries.append("Role: %s" % coordin)
    summaries.append("SQL-Port: 30015")
    if acting.lower() != "yes":
        summaries.append("not acting")
    msg = "; ".join(summaries)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": msg}}