_TEMP_TYPES = [4, 5, 13, 14, 15, 16, 17, 18, 19, 20]
_FAN_TYPES = [9, 10, 11, 26, 27, 28]

_BASE = "1.3.6.1.4.1.232.167.2.4.5.2.1"
_OID_ORDER = [".1", ".2", ".3", ".4", ".5", ".6", ".7"]

def _walk_table(ctx, host, community, col_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn",
         "-Ot", host, col_oid],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    if res.stdout == "":
        return []
    lines = []
    for line in res.stdout.splitlines():
        if line == "":
            continue
        idx = line.find(" ")
        if idx < 0:
            continue
        oid_part = line[:idx]
        val_part = line[idx + 1:]
        suffix = oid_part[len(col_oid):]
        if suffix.startswith("."):
            suffix = suffix[1:]
        lines.append((suffix, val_part))
    return lines

def _find_by_index(rows, idx):
    for r_idx in rows:
        if r_idx[0] == idx:
            return r_idx[1]
    return None

def _gather(ctx, host, community):
    cols = {}
    for oid_suffix in _OID_ORDER:
        col = _walk_table(ctx, host, community, _BASE + oid_suffix)
        if col == None:
            return None
        cols[oid_suffix] = col
    if len(cols[".3"]) == 0:
        return {}
    section = {}
    for idx_val, name_val in cols[".3"]:
        if idx_val not in cols[".1"]:
            continue
        t = _find_by_index(cols[".1"], idx_val)
        s = _find_by_index(cols[".2"], idx_val)
        v = _find_by_index(cols[".4"], idx_val)
        h = _find_by_index(cols[".5"], idx_val)
        lo = _find_by_index(cols[".6"], idx_val)
        if t == None or s == None or v == None or h == None or lo == None:
            continue
        ti = _to_int(t)
        if ti == None:
            continue
        si = _to_int(s)
        if si == None:
            continue
        vi = _to_float(v)
        if vi == None:
            continue
        hi = _to_float(h)
        if hi == None:
            continue
        lo_f = _to_float(lo)
        if lo_f == None:
            continue
        section[idx_val] = {
            "type": ti,
            "name": name_val,
            "status": si,
            "value": vi,
            "high": hi,
            "low": lo_f,
        }
    return section

def _to_int(val):
    val = val.strip()
    if val == "" or val == "None":
        return None
    if val.isdigit():
        return int(val)
    if val.startswith("-") and val[1:].isdigit():
        return int(val)
    return None

def _to_float(val):
    val = val.strip()
    if val == "" or val == "None":
        return None
    try_val = val
    if try_val.startswith("\"") and try_val.endswith("\""):
        try_val = try_val[1:-1]
    parts = try_val.split(".")
    ok = True
    if len(parts) == 1:
        ok = parts[0].isdigit() or (parts[0].startswith("-") and parts[0][1:].isdigit())
    elif len(parts) == 2:
        ok = _is_digit_str(parts[0]) and _is_digit_str(parts[1])
    else:
        ok = False
    if not ok:
        return None
    return float(try_val)

def _is_digit_str(s):
    if s == "":
        return True
    if s.startswith("-"):
        return s[1:].isdigit()
    return s.isdigit()

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    section = _gather(ctx, host, community)
    if section == None:
        return {"changed": False, "msg": "not present", "data": {"discovery": [], "host_labels": {}}}
    if params.get("_discover"):
        out = []
        for entry in section.values():
            if entry["type"] in _FAN_TYPES:
                out.append({"item": entry["name"], "params": {"levels": (1000, 500)}, "metrics": ["fanspeed"]})
        return {"changed": False, "msg": "discovered %d fan sensors" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    entry = None
    for e in section.values():
        if e["name"] == item:
            entry = e
            break
    if entry == None:
        return {"changed": False, "msg": "no fan sensor found: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    warn = params.get("warn")
    crit = params.get("crit")
    levels = params.get("levels", (1000, 500))
    if warn == None and crit == None:
        if len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]
    value = entry["value"]
    state = "OK"
    if warn != None and crit != None:
        if value <= crit:
            state = "CRIT"
        elif value <= warn:
            state = "WARN"
    return {"changed": False, "msg": "Sensor %s: %s rpm" % (item, value), "data": {"state": state, "metrics": {"fanspeed": value}, "details": ""}}