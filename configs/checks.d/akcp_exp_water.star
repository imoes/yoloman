RELAY_STATES = {
    "1": (2, "no status"),
    "2": (0, "normal"),
    "4": (2, "high critical"),
    "6": (2, "low critical"),
    "7": (2, "sensor error"),
    "8": (2, "relay on"),
    "9": (0, "relay off"),
}

ST_MAP = {0: "OK", 1: "WARN", 2: "CRIT"}

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

def _sysinfo_oid(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-OQv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return None
    return res.stdout.strip()

def _walk(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return []
    rows = []
    lines = res.stdout.splitlines()
    for line in lines:
        sp = line.split(None, 1)
        if len(sp) != 2:
            continue
        rows.append((sp[0], sp[1]))
    return rows

def _detect(ctx, params):
    sys_oid = _sysinfo_oid(ctx, params)
    if sys_oid == None:
        return "none"
    if sys_oid.startswith(".1.3.6.1.4.1.3854.1"):
        exp_rows = _walk(ctx, params, ".1.3.6.1.4.1.3854.2.3.9.1")
        if len(exp_rows) > 0:
            return "exp"
    if sys_oid.startswith(".1.3.6.1.4.1.3854"):
        sp_rows = _walk(ctx, params, ".1.3.6.1.4.1.3854.3.5.9.1")
        exp_rows = _walk(ctx, params, ".1.3.6.1.4.1.3854.2.3.9.1")
        if len(sp_rows) > 0 and len(exp_rows) == 0:
            return "sp2plus"
    return "none"

def _col_rows(ctx, params, base, col):
    full = base + "." + col
    rows = _walk(ctx, params, full)
    out = []
    for r in rows:
        o = r[0]
        val = r[1]
        idx = o[len(full) + 1:]
        out.append((idx, val))
    return out

def _fetch_section(ctx, params):
    kind = _detect(ctx, params)
    if kind == "exp":
        base = ".1.3.6.1.4.1.3854.2.3.9.1"
    elif kind == "sp2plus":
        base = ".1.3.6.1.4.1.3854.3.5.9.1"
    else:
        return kind, []
    cols = ["2", "6", "8"]
    col_map = {}
    for c in cols:
        col_map[c] = _col_rows(ctx, params, base, c)
    indices_set = {}
    for c in cols:
        for pair in col_map[c]:
            indices_set[pair[0]] = True
    indices = sorted(list(indices_set))
    by_idx = {}
    for c in cols:
        for pair in col_map[c]:
            idx = pair[0]
            val = pair[1]
            if idx not in by_idx:
                by_idx[idx] = {}
            by_idx[idx][c] = val
    section = []
    for idx in indices:
        e = by_idx[idx]
        desc = e.get("2", "")
        status = e.get("6", "")
        online = e.get("8", "")
        section.append([desc, status, online])
    return kind, section

def _discover(ctx, params):
    kind, section = _fetch_section(ctx, params)
    if kind == "none":
        return {"changed": False, "msg": "no AKCP device detected", "data": {"discovery": [], "host_labels": {}}}
    items = []
    for row in section:
        desc = row[0]
        online = row[2]
        if online == "1":
            entry = {"item": desc, "params": {}, "metrics": []}
            items.append(entry)
    return {"changed": False, "msg": "discovered %d water sensors" % len(items), "data": {"discovery": items, "host_labels": {}}}

def _check(ctx, params):
    kind, section = _fetch_section(ctx, params)
    if kind == "none":
        return {"changed": False, "msg": "no AKCP device detected", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    item = params.get("item", "")
    for row in section:
        desc = row[0]
        status = row[1]
        online = row[2]
        if desc == item:
            if online != "1":
                return {"changed": False, "msg": "Water %s: sensor is offline" % item, "data": {"state": "CRIT", "metrics": {}, "details": "sensor is offline"}}
            if status in RELAY_STATES:
                st_num, st_name = RELAY_STATES[status]
                state = ST_MAP.get(st_num, "UNKNOWN")
                return {"changed": False, "msg": "Water %s: %s" % (item, st_name), "data": {"state": state, "metrics": {}, "details": st_name}}
            return {"changed": False, "msg": "Water %s: unknown status %s" % (item, status), "data": {"state": "UNKNOWN", "metrics": {}, "details": "unknown status"}}
    return {"changed": False, "msg": "no such water sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}