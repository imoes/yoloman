def _is_float(s):
    if s == "":
        return False
    body = s
    if body.startswith("-") or body.startswith("+"):
        body = body[1:]
    if body.count(".") > 1:
        return False
    parts = body.split(".")
    for p in parts:
        if p == "":
            continue
        if not p.isdigit():
            return False
    return True


def main(ctx, params):
    sysid_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", "-OQv", params.get("host", "localhost"),
         ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    sysid = ""
    if sysid_res.rc == 0:
        sysid = sysid_res.stdout.strip()

    if sysid != ".1.3.6.1.4.1.4998.2.1":
        if params.get("_discover"):
            return {"changed": False, "msg": "not an Arris CMTS (sysObjectID mismatch)",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no Arris CMTS detected at %s" % params.get("host", "localhost"),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.4998.1.1.5.3.2.1.1"

    walk_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".2"],
        mutates=False,
    )
    if walk_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "snmpwalk failed for heap table",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "cannot read heap table from %s" % host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    col_cid = {}
    col_heap = {}
    col_heap_free = {}
    for line in walk_res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:].strip()
        suffix = oid[len(base + ".2") + 1:]
        if suffix == "":
            continue
        col_oid = oid[:oid.rfind("." + suffix)]
        if col_oid == base + ".2":
            col_cid[suffix] = val
        elif col_oid == base + ".3":
            col_heap[suffix] = val
        elif col_oid == base + ".4":
            col_heap_free[suffix] = val

    for col_oid, target in [(base + ".3", col_heap), (base + ".4", col_heap_free)]:
        r = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
                    mutates=False)
        if r.rc != 0:
            continue
        for line in r.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip()
            suffix = oid[len(col_oid) + 1:]
            if suffix == "":
                continue
            target[suffix] = val

    parsed = {}
    for suffix, cid_val in col_cid.items():
        cid_int = int(cid_val) if cid_val.isdigit() else 0
        item = str(cid_int - 1)
        heap_s = col_heap.get(suffix, "")
        hf_s = col_heap_free.get(suffix, "")
        heap_f = float(heap_s) if _is_float(heap_s) else 0.0
        hf_f = float(hf_s) if _is_float(hf_s) else 0.0
        parsed[item] = {"mem_used": heap_f - hf_f, "mem_total": heap_f}

    if params.get("_discover"):
        discovery = []
        for item in sorted(parsed.keys()):
            discovery.append({"item": item, "params": {"levels": (80.0, 90.0)},
                              "metrics": ["mem_used"]})
        return {"changed": False,
                "msg": "discovered %d memory modules" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if item not in parsed:
        return {"changed": False, "msg": "no data for Memory Module %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = parsed[item]
    mem_used = data["mem_used"]
    mem_total = data["mem_total"]
    levels = params.get("levels", (80.0, 90.0))
    mode = "abs_used"
    mem_levels = None
    if type(levels) == "list" and len(levels) == 2:
        if type(levels[0]) == "float" or type(levels[0]) == "int":
            first = levels[0]
            if type(first) == "float":
                mode = "perc_used"
            mem_levels = (mode, levels)
    elif type(levels) == "tuple" and len(levels) == 2:
        first = levels[0]
        if type(first) == "float":
            mode = "perc_used"
        mem_levels = (mode, levels)

    state = "OK"
    details = "Usage: %s of %s bytes" % (str(mem_used), str(mem_total))
    if mem_total > 0:
        pct = (mem_used / mem_total) * 100.0
        if mode == "perc_used" and mem_levels != None:
            warn, crit = mem_levels[1][0], mem_levels[1][1]
            if pct >= crit:
                state = "CRIT"
            elif pct >= warn:
                state = "WARN"
            details = "Usage: %f%%" % pct
        elif mode == "abs_used" and mem_levels != None:
            warn, crit = mem_levels[1][0], mem_levels[1][1]
            if mem_used >= crit:
                state = "CRIT"
            elif mem_used >= warn:
                state = "WARN"
        metrics = {"mem_used": mem_used, "mem_total": mem_total}
        if mode == "perc_used":
            metrics = {"mem_used": mem_used, "mem_total": mem_total, "mem_used_pct": pct}
    else:
        metrics = {"mem_used": mem_used, "mem_total": mem_total}

    return {"changed": False, "msg": details,
            "data": {"state": state, "metrics": metrics, "details": details}}