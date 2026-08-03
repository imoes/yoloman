def _pow(base, exp):
    result = 1.0
    for _ in range(exp):
        result = result * base
    return result

def _to_bytes(value, uom):
    exponents = {"KB": 1, "MB": 2, "GB": 3, "TB": 4}
    exponent = exponents.get(uom, 0)
    if not _is_number(value):
        return None
    return float(value) * _pow(1024.0, exponent)

def _is_number(s):
    if type(s) != "string":
        return False
    if len(s) == 0:
        return False
    neg = False
    body = s
    if body[0] == "-":
        neg = True
        body = body[1:]
    if len(body) == 0:
        return False
    seen_dot = False
    for ch in body:
        if ch == ".":
            if seen_dot:
                return False
            seen_dot = True
        elif ch < "0" or ch > "9":
            return False
    return True

def _parse_value(v, uom):
    if v == None:
        return None
    return _to_bytes(v, uom)

def _level_tuple(levels):
    if levels == None:
        return None
    if type(levels) != "list":
        return None
    if len(levels) != 2:
        return None
    return (levels[0], levels[1])

def _levels_pct(levels):
    if levels == None:
        return False
    if type(levels) != "list":
        return False
    if len(levels) != 2:
        return False
    return type(levels[1]) == "float"

def _grade(value, warn, crit, upper):
    if value == None:
        return "OK"
    if warn == None and crit == None:
        return "OK"
    if upper:
        if crit != None and value >= crit:
            return "CRIT"
        if warn != None and value >= warn:
            return "WARN"
    else:
        if crit != None and value <= crit:
            return "CRIT"
        if warn != None and value <= warn:
            return "WARN"
    return "OK"

def _grade_state(value, warn, crit, upper):
    s = _grade(value, warn, crit, upper)
    if s == "OK":
        return "OK", 0
    if s == "WARN":
        return "WARN", 1
    return "CRIT", 2

def _parse_tablespaces(text):
    section = {}
    for line in text.splitlines():
        if not line:
            continue
        parts = line.split()
        if len(parts) < 14:
            continue
        pairs = list(zip(parts[:14:2], parts[1:14:2]))
        values = []
        for p in pairs[1:]:
            values.append(_parse_value(p[0], p[1]))
        keys = ["size", "unallocated", "reserved", "data", "indexes", "unused"]
        td = {}
        for i in range(len(keys)):
            td[keys[i]] = values[i]
        error_msg = None
        if len(parts) > 14 and parts[14].startswith("ERROR:"):
            error_msg = " ".join(parts[15:])
        item = parts[0] + " " + parts[1]
        td["error"] = error_msg
        section[item] = td
    return section

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["sqlcmd", "-Q", "SELECT DB_NAME() AS db, name FROM sys.master_files WITH (NOLOCK)", "-W", "-s", " "], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "sqlcmd not available", "data": {"discovery": []}}
        text = res.stdout
        if not text or text.strip() == "":
            return {"changed": False, "msg": "no MSSQL instance found", "data": {"discovery": []}}
        section = _parse_tablespaces(text)
        out = []
        for item, ts in section.items():
            if ts.get("error") == None:
                out.append({"item": item, "params": {}, "metrics": ["size", "unallocated", "reserved", "data", "indexes", "unused"]})
        if len(out) == 0:
            return {"changed": False, "msg": "no MSSQL instance found", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["sqlcmd", "-Q", "SELECT DB_NAME() AS db, name FROM sys.master_files WITH (NOLOCK)", "-W", "-s", " "], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "MSSQL not present: sqlcmd unavailable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    text = res.stdout
    if not text or text.strip() == "":
        return {"changed": False, "msg": "MSSQL not present: no tablespaces", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_tablespaces(text)
    ts = section.get(item)
    if ts == None:
        return {"changed": False, "msg": "MSSQL tablespace not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details_parts = []
    worst_state = "OK"
    worst_rank = 0

    if ts.get("error") != None:
        worst_rank = 2
        worst_state = "CRIT"
        details_parts.append(ts["error"])

    size = ts.get("size")
    if size != None:
        size_levels = _level_tuple(params.get("size"))
        st = "OK"
        rank = 0
        if size_levels != None:
            st, rank = _grade_state(size, size_levels[0], size_levels[1], True)
        if rank > worst_rank:
            worst_rank = rank
            worst_state = st
        metrics["size"] = size
        details_parts.append("Size: %s" % str(size))

    metric_specs = [
        ("unallocated", ts.get("unallocated"), "Unallocated space", params.get("unallocated"), None),
        ("reserved", ts.get("reserved"), "Reserved space", None, params.get("reserved")),
        ("data", ts.get("data"), "Data", None, params.get("data")),
        ("indexes", ts.get("indexes"), "Indexes", None, params.get("indexes")),
        ("unused", ts.get("unused"), "Unused", None, params.get("unused")),
    ]

    for mn, vb, label, levels_lower, levels_upper in metric_specs:
        if vb == None:
            continue
        metrics[mn] = vb
        levels_are_perc = _levels_pct(levels_upper) or _levels_pct(levels_lower)
        lu = None
        ll = None
        if not levels_are_perc:
            lu = _level_tuple(levels_upper)
            ll = _level_tuple(levels_lower)
        st_low = "OK"
        rank_low = 0
        if ll != None:
            st_low, rank_low = _grade_state(vb, ll[0], ll[1], False)
        st_high = "OK"
        rank_high = 0
        if lu != None:
            st_high, rank_high = _grade_state(vb, lu[0], lu[1], True)
        if rank_low > worst_rank:
            worst_rank = rank_low
            worst_state = st_low
        if rank_high > worst_rank:
            worst_rank = rank_high
            worst_state = st_high
        details_parts.append("%s: %s" % (label, str(vb)))
        if size != None and size != 0:
            pct = 100.0 * vb / size
            metrics[mn + "_percent"] = pct
            lu_pct = None
            ll_pct = None
            if levels_are_perc:
                lu_pct = _level_tuple(levels_upper)
                ll_pct = _level_tuple(levels_lower)
            st_p = "OK"
            rank_p = 0
            if lu_pct != None:
                st_p, rank_p = _grade_state(pct, lu_pct[0], lu_pct[1], True)
            st_p2 = "OK"
            rank_p2 = 0
            if ll_pct != None:
                st_p2, rank_p2 = _grade_state(pct, ll_pct[0], ll_pct[1], False)
            if rank_p > worst_rank:
                worst_rank = rank_p
                worst_state = st_p
            if rank_p2 > worst_rank:
                worst_rank = rank_p2
                worst_state = st_p2
            details_parts.append("%s: %f%%" % (label, pct))

    msg = item + " - " + ", ".join(details_parts)
    return {"changed": False, "msg": msg, "data": {"state": worst_state, "metrics": metrics, "details": "; ".join(details_parts)}}