UOM_MULT = {"KB": 1024, "MB": 1048576, "GB": 1073741824, "TB": 1099511627776}
STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _to_bytes(val_str, uom):
    val_str = val_str.strip().replace(",", "")
    if not val_str.replace(".", "", 1).isdigit():
        return -1
    mult = UOM_MULT.get(uom.strip(), 1)
    return float(val_str) * mult

def _render_bytes(b):
    if b < 0:
        return "N/A"
    if b < 1024:
        return "%d B" % int(b)
    if b < 1048576:
        return "%f KB" % (b / 1024.0)
    if b < 1073741824:
        return "%f MB" % (b / 1048576.0)
    if b < 1099511627776:
        return "%f GB" % (b / 1073741824.0)
    return "%f TB" % (b / 1099511627776.0)

def _worst(s1, s2):
    if STATE_ORDER.get(s1, 0) >= STATE_ORDER.get(s2, 0):
        return s1
    return s2

def _state_suffix(state):
    if state == "WARN":
        return " (!)"
    if state == "CRIT":
        return " (!!)"
    return ""

def _check_upper(value, warn, crit):
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def _check_lower(value, warn, crit):
    if crit != None and value <= crit:
        return "CRIT"
    if warn != None and value <= warn:
        return "WARN"
    return "OK"

def _parse_size_pair(s):
    s = s.strip()
    parts = s.rsplit(" ", 1)
    if len(parts) != 2:
        return -1
    return _to_bytes(parts[0], parts[1])

def _run_sql(ctx, params, query):
    host = params.get("host", "localhost")
    port = params.get("port", 1433)
    user = params.get("user", "sa")
    password = params.get("password", "")
    return ctx.run([
        "sqlcmd",
        "-S", "%s,%s" % (host, str(port)),
        "-U", user,
        "-P", password,
        "-Q", query,
        "-h", "-1",
        "-W",
        "-s", "|",
    ], mutates=False)

def _get_databases(ctx, params):
    res = _run_sql(ctx, params,
        "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' ORDER BY name")
    if res.rc != 0:
        fail("sqlcmd failed (rc=%d): %s" % (res.rc, res.stderr.strip()))
    dbs = []
    for line in res.stdout.splitlines():
        s = line.strip()
        if s and not s.startswith("(") and not s.startswith("---"):
            dbs.append(s)
    return dbs

def _get_tablespace(ctx, params, dbname):
    res = _run_sql(ctx, params,
        "SET NOCOUNT ON; USE [%s]; EXEC sp_spaceused;" % dbname)
    if res.rc != 0:
        return None
    lines = []
    for l in res.stdout.splitlines():
        s = l.strip()
        if s and not s.startswith("(") and not s.startswith("---"):
            lines.append(s)
    if len(lines) < 2:
        return None
    parts1 = lines[0].split("|")
    if len(parts1) < 3:
        return None
    parts2 = None
    for line in lines[1:]:
        p = line.split("|")
        if len(p) >= 4:
            parts2 = p
            break
    if parts2 == None:
        return None
    return {
        "size":        _parse_size_pair(parts1[1]),
        "unallocated": _parse_size_pair(parts1[2]),
        "reserved":    _parse_size_pair(parts2[0]),
        "data":        _parse_size_pair(parts2[1]),
        "indexes":     _parse_size_pair(parts2[2]),
        "unused":      _parse_size_pair(parts2[3]),
    }

def main(ctx, params):
    instance = params.get("instance", "MSSQLSERVER")

    if params.get("_discover"):
        dbs = _get_databases(ctx, params)
        items = []
        for db in dbs:
            items.append({
                "item": "%s %s" % (instance, db),
                "params": {},
                "metrics": ["size", "unallocated", "reserved", "data", "indexes", "unused"],
            })
        return {
            "changed": False,
            "msg": "discovered %d tablespaces" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    space_idx = item.find(" ")
    if space_idx < 0:
        return {
            "changed": False,
            "msg": "invalid item (expected 'INSTANCE DBNAME'): " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    dbname = item[space_idx + 1:]

    ts = _get_tablespace(ctx, params, dbname)
    if ts == None:
        return {
            "changed": False,
            "msg": "could not retrieve tablespace data for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    overall = "OK"
    parts = []
    metrics_out = {}
    size = ts["size"]

    if size >= 0:
        metrics_out["size"] = size
        s = _check_upper(size, params.get("size_warn"), params.get("size_crit"))
        overall = _worst(overall, s)
        parts.append("Size: %s%s" % (_render_bytes(size), _state_suffix(s)))

    for field, label, is_lower in [
        ("unallocated", "Unallocated", True),
        ("reserved",    "Reserved",    False),
        ("data",        "Data",        False),
        ("indexes",     "Indexes",     False),
        ("unused",      "Unused",      False),
    ]:
        val = ts[field]
        if val < 0:
            continue
        metrics_out[field] = val
        w = params.get(field + "_warn")
        c = params.get(field + "_crit")
        if is_lower:
            s = _check_lower(val, w, c)
        else:
            s = _check_upper(val, w, c)
        overall = _worst(overall, s)
        parts.append("%s: %s%s" % (label, _render_bytes(val), _state_suffix(s)))
        if size > 0:
            pct = 100.0 * val / size
            pct_w = params.get(field + "_pct_warn")
            pct_c = params.get(field + "_pct_crit")
            if pct_w != None or pct_c != None:
                if is_lower:
                    s_pct = _check_lower(pct, pct_w, pct_c)
                else:
                    s_pct = _check_upper(pct, pct_w, pct_c)
                overall = _worst(overall, s_pct)
                if s_pct != "OK":
                    parts.append("%f%%%s" % (pct, _state_suffix(s_pct)))

    summary = ", ".join(parts) if parts else "no tablespace data"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": overall,
            "metrics": metrics_out,
            "details": "",
        },
    }