def _empty_section():
    return (None, {})


def _parse_db2_dbs(raw_section):
    current_instance = None
    dbs = {}
    global_timestamp = None
    for line in raw_section:
        if len(line) < 2:
            continue
        first = line[0]
        if first.startswith("TIMESTAMP") and current_instance == None:
            global_timestamp = int(first[1])
            continue
        if first.startswith("[[["):
            current_instance = first[3:-3]
            dbs[current_instance] = []
        else:
            if current_instance != None:
                dbs[current_instance].append(line)
    return (global_timestamp, dbs)


def _to_float(value):
    s = str(value)
    neg = s.startswith("-")
    body = s[1:] if neg else s
    if body == "" or body == "." or body.count(".") > 1:
        return 0.0
    for ch in body:
        if ch < "0" or ch > "9":
            if ch != ".":
                return 0.0
    return float(s)


def _gather_db2_sort_data(ctx):
    res2 = ctx.run(["db2", "list", "applications"], mutates=False)
    if res2.rc == 127:
        return _empty_section()
    res = ctx.run(["db2", "get", "db2", "sort", "statistics"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return _empty_section()
    raw = []
    for ln in res.stdout.splitlines():
        raw.append(ln.split())
    return _parse_db2_dbs(raw)


def _discover(ctx, params):
    section = _gather_db2_sort_data(ctx)
    discovery = []
    for key in section[1].keys():
        discovery.append({
            "item": key,
            "params": {"levels_perc": params.get("levels_perc", (2.0, 4.0))},
            "metrics": ["sort_overflow"],
        })
    return {
        "changed": False,
        "msg": "discovered %d items" % len(discovery),
        "data": {"discovery": discovery},
    }


def _check(ctx, params):
    item = params.get("item", "")
    section = _gather_db2_sort_data(ctx)
    dbs = section[1]
    db = dbs.get(item)
    if not db:
        return {
            "changed": False,
            "msg": "Login into database failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    total = 0.0
    overflows = 0.0
    for x in db:
        last = x[-1]
        label = x[-2] if len(x) >= 2 else ""
        if label == "sorts":
            total = _to_float(last)
        elif label == "overflows":
            overflows = _to_float(last)
    warn, crit = params.get("levels_perc", (2.0, 4.0))
    if total > 0:
        overflow_perc = overflows * 100.0 / total
    else:
        overflow_perc = 0.0
    if overflow_perc >= crit:
        state = "CRIT"
    elif overflow_perc >= warn:
        state = "WARN"
    else:
        state = "OK"
    msg = "%f%% sort overflow" % overflow_perc
    if state != "OK":
        msg = msg + " (levels at %f%%/%f%%)" % (warn, crit)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"sort_overflow": overflow_perc},
            "details": "Sort overflows: %d, Total sorts: %d" % (int(overflows), int(total)),
        },
    }


def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)