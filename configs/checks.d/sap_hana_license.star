def main(ctx, params):
    if params.get("_discover"):
        instances = _discover_instances(ctx)
        out = []
        for inst in instances:
            out.append({
                "item": inst,
                "params": {"license_usage_perc": [80.0, 90.0]},
                "metrics": ["license_size", "license_usage_perc"],
            })
        return {
            "changed": False,
            "msg": "discovered %d SAP HANA instances" % len(out),
            "data": {"discovery": out},
        }
    return _check(ctx, params)


def _hdbsql_available(ctx):
    res = ctx.run(["hdbsql", "-version"], mutates=False)
    if res.rc == 127:
        return False
    if res.rc == 0 and ("hdbsql" in res.stdout or "HDBSQL" in res.stderr):
        return True
    res2 = ctx.run(["which", "hdbsql"], mutates=False)
    return res2.rc == 0 and res2.stdout.strip() != ""


def _discover_instances(ctx):
    if not _hdbsql_available(ctx):
        return []
    res = ctx.run(["hdbsql", "-e", "SELECT * FROM M_SERVICES"], mutates=False)
    if res.rc != 0:
        return []
    instances = []
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 3:
            continue
        host = f[0]
        port = f[1]
        inst = "%s:%s" % (host, port)
        instances.append(inst)
    if not instances:
        res2 = ctx.run(["hdbsql", "-e", "SELECT 1"], mutates=False)
        if res2.rc == 0:
            instances = ["SYSTEMDB"]
    return instances


def _check(ctx, params):
    item = params.get("item", "")
    if not _hdbsql_available(ctx):
        return {
            "changed": False,
            "msg": "hdbsql not installed on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(["hdbsql", "-e", "SELECT * FROM M_SERVICES"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "hdbsql query failed: %s" % res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sections = {}
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 3:
            continue
        host = f[0]
        port = f[1]
        inst_name = "%s:%s" % (host, port)
        if inst_name == item or (item == "SYSTEMDB" and host == "SYSTEMDB") or (item == "SYSTEMDB" and not item):
            entries = sections.setdefault(inst_name, [])
            entries.append(f)

    if item == "" or item == "SYSTEMDB":
        target = item if (item == "" and "SYSTEMDB" in sections) else (item if item in sections else None)
    else:
        target = item if item in sections else None

    if target == None or len(sections.get(target, [])) == 0:
        if item == "" and "SYSTEMDB" not in sections:
            res2 = ctx.run(["hdbsql", "-e", "SELECT 1"], mutates=False)
            if res2.rc == 0:
                target = "SYSTEMDB"
        if target == None or len(sections.get(target, [])) == 0:
            return {
                "changed": False,
                "msg": "no SAP HANA instance found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    data = _query_license_data(ctx, target)
    if data == {}:
        return {
            "changed": False,
            "msg": "Login into database failed.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    enforced_raw = data.get("enforced", "unknown")
    enforced_bool = _parse_maybe_bool(enforced_raw)
    permanent_raw = data.get("permanent", "unknown")
    permanent_bool = _parse_maybe_bool(permanent_raw)
    valid_raw = data.get("valid", "unknown")
    valid_bool = _parse_maybe_bool(valid_raw)
    size = data.get("size", 0)
    limit = data.get("limit", 0)
    expiration_date = data.get("expiration_date", "?")

    metrics = {}
    details = ""

    if enforced_bool == True:
        if isinstance(size, int) and isinstance(limit, int):
            metrics["license_size"] = size
        if isinstance(size, int) and isinstance(limit, int) and limit > 0:
            usage_perc = 100.0 * size / limit
            metrics["license_usage_perc"] = usage_perc
        warn_lev = params.get("license_size")
        if warn_lev != None:
            w = warn_lev[0] if isinstance(warn_lev, list) else warn_lev
            c = warn_lev[1] if isinstance(warn_lev, list) else None
        usage_lev = params.get("license_usage_perc")
        if usage_lev == None:
            usage_lev = [80.0, 90.0]
        wu = usage_lev[0] if isinstance(usage_lev, list) else 80.0
        cu = usage_lev[1] if isinstance(usage_lev, list) else 90.0
    else:
        wu = 0
        cu = 0
        usage_perc = 0

    state = "OK"

    if enforced_bool == True:
        if limit > 0:
            if usage_perc >= cu:
                state = _worse(state, "CRIT")
            elif usage_perc >= wu:
                state = _worse(state, "WARN")
    elif enforced_bool == None:
        state = _worse(state, "UNKNOWN")
        details = details + "Status: unknown[%s]\n" % enforced_raw

    if enforced_bool == False:
        details = details + "Status: unlimited\n"
    elif enforced_bool == True and isinstance(size, int) and isinstance(limit, int):
        details = details + "Size: %s, Usage: %s%%\n" % (_render_bytes(size), _render_percent(usage_perc))

    if permanent_bool == True:
        details = details + "License: %s\n" % permanent_raw
    else:
        if state == "OK":
            state = "WARN"
        details = details + "License: not %s\n" % permanent_raw

    if valid_bool == False:
        if state == "OK":
            state = "WARN"
        details = details + "not %s\n" % valid_raw

    if expiration_date != "?":
        if state == "OK":
            state = "WARN"
        details = details + "Expiration date: %s\n" % expiration_date

    return {
        "changed": False,
        "msg": state + " - " + details.strip(),
        "data": {"state": state, "metrics": metrics, "details": details.strip()},
    }


def _worse(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(a, 0) >= order.get(b, 0):
        return a
    return b


def _parse_maybe_bool(value):
    if value == None:
        return None
    v = str(value).lower()
    if v == "true":
        return True
    if v == "false":
        return False
    return None


def _query_license_data(ctx, target):
    res = ctx.run(["hdbsql", "-e", "SELECT * FROM M_LICENSES"], mutates=False)
    if res.rc != 0:
        return {}
    data = {}
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) >= 7:
            data = {
                "enforced": f[0],
                "permanent": f[1],
                "locked": f[2],
                "size": int(f[3]) if f[3].lstrip("-").isdigit() else f[3],
                "limit": int(f[4]) if f[4].lstrip("-").isdigit() else f[4],
                "valid": f[5],
                "expiration_date": f[6],
            }
            break
    return data


def _render_bytes(n):
    if n >= 1073741824:
        return "%f GB" % (float(n) / 1073741824)
    if n >= 1048576:
        return "%f MB" % (float(n) / 1048576)
    if n >= 1024:
        return "%f KB" % (float(n) / 1024)
    return "%d B" % n


def _render_percent(p):
    return "%f" % p