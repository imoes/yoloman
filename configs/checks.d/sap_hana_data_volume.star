_DEFAULT_WARN = 80.0
_DEFAULT_CRIT = 90.0
_MB = 1048576.0

_VOLUMES_QUERY = "SELECT v.VOLUME_TYPE, v.SERVICE_NAME, CAST(v.VOLUME_ID AS NVARCHAR), v.USED_SIZE, v.TOTAL_SIZE FROM M_VOLUMES v WHERE v.VOLUME_TYPE NOT IN ('TRACE') ORDER BY v.VOLUME_TYPE, v.SERVICE_NAME, v.VOLUME_ID"

_ITEM_SUFFIXES = ["", " Disk", " Disk Net Data"]

def _hdbsql(ctx, params, query):
    hdbsql_bin = params.get("hdbsql", "hdbsql")
    host = params.get("host", "localhost")
    port = str(params.get("port", 30015))
    user = params.get("user", "SYSTEM")
    pw = params.get("password", "")
    return ctx.run(
        [hdbsql_bin, "-n", host + ":" + port, "-u", user, "-p", pw,
         "-a", "-x", "-F", "\t", query],
        mutates=False,
    )

def _sid_inst(ctx, params):
    res = _hdbsql(ctx, params, "SELECT SYSTEM_ID FROM M_DATABASE")
    sid = "SAP"
    if res.rc == 0 and res.stdout.strip():
        lines = res.stdout.strip().splitlines()
        if len(lines) > 0:
            sid = lines[0].strip().strip('"')
    port = int(params.get("port", 30015))
    inst_num = port // 100 - 300
    if (inst_num >= 0) and (inst_num <= 99):
        inst = "%d" % inst_num
    else:
        inst = "00"
    return sid + "/" + inst

def _parse_tsv(stdout, min_cols):
    rows = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = [p.strip().strip('"') for p in line.split("\t")]
        if len(parts) >= min_cols:
            rows.append(parts)
    return rows

def _safe_float(s):
    s = s.strip()
    if not s or s in ("NULL", "null", "?"):
        return 0.0
    pos = s[1:] if s.startswith("-") else s
    dot_count = pos.count(".")
    if dot_count > 1:
        return 0.0
    clean = pos.replace(".", "")
    if not clean or not clean.isdigit():
        return 0.0
    return float(s)

def _state_for_pct(pct, params):
    warn = params.get("warn", _DEFAULT_WARN)
    crit = params.get("crit", _DEFAULT_CRIT)
    if pct >= crit:
        return "CRIT"
    if pct >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        prefix = _sid_inst(ctx, params)
        res = _hdbsql(ctx, params, _VOLUMES_QUERY)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "hdbsql failed: " + res.stderr,
                "data": {"discovery": []},
            }
        rows = _parse_tsv(res.stdout, 5)
        discovery = []
        for row in rows:
            base = prefix + " - " + row[0] + " " + row[2]
            for suffix in _ITEM_SUFFIXES:
                discovery.append({
                    "item": base + suffix,
                    "params": {"warn": _DEFAULT_WARN, "crit": _DEFAULT_CRIT},
                    "metrics": ["used_percent", "used_mb", "avail_mb", "total_mb"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    prefix = _sid_inst(ctx, params)
    res = _hdbsql(ctx, params, _VOLUMES_QUERY)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "hdbsql failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows = _parse_tsv(res.stdout, 5)
    found_row = None
    for row in rows:
        if found_row != None:
            break
        base = prefix + " - " + row[0] + " " + row[2]
        for suffix in _ITEM_SUFFIXES:
            if item == base + suffix:
                found_row = row
                break

    if found_row == None:
        return {
            "changed": False,
            "msg": "Volume not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    svc = found_row[1]
    used_mb = _safe_float(found_row[3]) / _MB
    total_mb = _safe_float(found_row[4]) / _MB

    if total_mb <= 0.0:
        return {
            "changed": False,
            "msg": item + ": total size is zero",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Service: " + svc},
        }

    avail_mb = total_mb - used_mb
    pct = used_mb / total_mb * 100.0
    state = _state_for_pct(pct, params)

    return {
        "changed": False,
        "msg": "%f%% used (%f of %f MB), Service: %s" % (pct, used_mb, total_mb, svc),
        "data": {
            "state": state,
            "metrics": {
                "used_percent": pct,
                "used_mb": used_mb,
                "avail_mb": avail_mb,
                "total_mb": total_mb,
            },
            "details": "Service: " + svc,
        },
    }