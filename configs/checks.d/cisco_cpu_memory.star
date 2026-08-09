def main(ctx, params):
    if params.get("_discover"):
        sys_descr = _snmpget(ctx, "1.3.6.1.2.1.1.1.0")
        if sys_descr == None or not _is_cisco(sys_descr):
            return {"changed": False, "msg": "no Cisco device found",
                    "data": {"discovery": []}}
        base = "1.3.6.1.4.1.9.9.109.1.1.1.1"
        col_oid = base + ".12"
        rows = _snmpwalk(ctx, col_oid)
        if not rows:
            return {"changed": False, "msg": "no ciscoCPUMemory entities",
                    "data": {"discovery": []}}
        indices = []
        for oid_val in rows:
            if not oid_val.startswith(col_oid + "."):
                continue
            idx = oid_val[len(col_oid) + 1:]
            if idx != "" and idx not in indices:
                indices.append(idx)
        name_map = _fetch_names(ctx)
        out = []
        for idx in indices:
            item = name_map.get(idx, idx)
            out.append({"item": item, "params": {}, "metrics": ["usage_percent"]})
        return {"changed": False,
                "msg": "discovered %d CPU memory instances" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    idx = _find_index_for_item(ctx, item)
    if idx == None:
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    used = _snmpget_int(ctx, "1.3.6.1.4.1.9.9.109.1.1.1.1.12." + idx)
    free = _snmpget_int(ctx, "1.3.6.1.4.1.9.9.109.1.1.1.1.13." + idx)
    reserved = _snmpget_int(ctx, "1.3.6.1.4.1.9.9.109.1.1.1.1.14." + idx)
    if used == None or free == None or reserved == None:
        return {"changed": False, "msg": "missing values for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if used == 0 and free == 0:
        return {"changed": False, "msg": "no data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    mem_total = used + free
    mem_occupied = used + reserved
    if not mem_total:
        return {"changed": False,
                "msg": "Cannot calculate memory usage: Device reports total memory 0",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    usage = mem_occupied * 100.0 / mem_total
    warn, crit = _levels(params.get("levels", (None, None)))
    state = "OK"
    if (warn != None and usage >= warn) or (crit != None and usage >= crit):
        state = "WARN"
    if crit != None and usage >= crit:
        state = "CRIT"
    return {"changed": False,
            "msg": "CPU Memory utilization: %s%% used" % _fmt(usage),
            "data": {"state": state, "metrics": {"usage_percent": usage}, "details": ""}}


def _is_cisco(desc):
    low = desc.lower()
    return "cisco" in low and "nx-os" not in low


def _snmpget(ctx, oid):
    host = _host(ctx)
    comm = _community(ctx)
    res = ctx.run(["snmpget", "-v2c", "-c", comm, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return _clean(res.stdout.strip())


def _snmpget_int(ctx, oid):
    val = _snmpget(ctx, oid)
    if val == None:
        return None
    return int(val) if _is_int(val) else None


def _is_int(s):
    if len(s) == 0:
        return False
    body = s
    if body[0] == "-" or body[0] == "+":
        body = body[1:]
    if len(body) == 0:
        return False
    for c in body:
        if c < "0" or c > "9":
            return False
    return True


def _snmpwalk(ctx, oid):
    host = _host(ctx)
    comm = _community(ctx)
    res = ctx.run(["snmpwalk", "-v2c", "-c", comm, "-Oqn", host, oid], mutates=False)
    if res.rc != 0:
        return []
    return res.stdout.splitlines()


def _fetch_names(ctx):
    base = "1.3.6.1.2.1.47.1.1.1"
    col_oid = base + ".1.7"
    rows = _snmpwalk(ctx, col_oid)
    m = {}
    for line in rows:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        if not oid_full.startswith(col_oid + "."):
            continue
        idx = oid_full[len(col_oid) + 1:]
        name = parts[1].strip().strip('"')
        m[idx] = name
    return m


def _find_index_for_item(ctx, item):
    names = _fetch_names(ctx)
    for idx, name in names.items():
        if name == item:
            return idx
    base = "1.3.6.1.4.1.9.9.109.1.1.1.1"
    col_oid = base + ".2"
    rows = _snmpwalk(ctx, col_oid)
    for line in rows:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        if not oid_full.startswith(col_oid + "."):
            continue
        idx = oid_full[len(col_oid) + 1:]
        if idx == item:
            return idx
    return None


def _levels(levels):
    warn = None
    crit = None
    if levels != None:
        if type(levels) == "list":
            warn = levels[0] if len(levels) > 0 else None
            crit = levels[1] if len(levels) > 1 else None
        elif type(levels) == "dict":
            warn = levels.get("warn")
            crit = levels.get("crit")
    return warn, crit


def _clean(v):
    if v.startswith('"') and v.endswith('"'):
        return v[1:-1]
    return v


def _fmt(v):
    return str(int(v * 10 + 0.5) / 10.0)


def _host(ctx):
    f = ctx.facts()
    h = f.get("host")
    return h if h != None else "localhost"


def _community(ctx):
    return "public"