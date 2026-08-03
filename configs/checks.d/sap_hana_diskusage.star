def main(ctx, params):
    if params.get("_discover"):
        hana = ctx.run(["which", "hdb"], mutates=False)
        if hana.rc != 0 or hana.rc == 127:
            hdb = ctx.run(["which", "hdbsql"], mutates=False)
            if hdb.rc != 0 or hdb.rc == 127:
                hdb = ctx.run(["which", "hdb"], mutates=False)
        if hdb.rc != 0 or hdb.rc == 127:
            return {"changed": False, "msg": "no sap hana client found", "data": {"discovery": []}}

        host = params.get("host", "localhost")
        port = params.get("port", "30015")
        user = params.get("user", "SYSTEM")
        pw = params.get("password", "")
        hana_port = params.get("hana_port", "30013")

        sql = "SELECT HOST, PORT, SQL_ADDRESS, SQL_PORT FROM M_SERVICES WHERE SERVICE_NAME = 'indexserver'"
        res = ctx.run(
            ["hdbsql", "-n", host + ":" + hana_port, "-u", user, "-p", pw, "-j", "-t", sql],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no sap hana indexservers discovered", "data": {"discovery": []}}

        rows = _hana_rows(res.stdout)
        out = []
        for r in rows:
            sid = params.get("site", "HANA")
            inst = sid + " - " + r.get("HOST", "")
            out.append({"item": inst, "params": {}, "metrics": ["used_percent", "size", "used", "avail"]})
        return {"changed": False, "msg": "discovered %d sap hana disk services" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    hana_port = params.get("hana_port", "30013")
    user = params.get("user", "SYSTEM")
    pw = params.get("password", "")

    sql = "SELECT HOST, PORT, SQL_ADDRESS, SQL_PORT FROM M_SERVICES WHERE SERVICE_NAME = 'indexserver'"
    res = ctx.run(["hdbsql", "-n", host + ":" + hana_port, "-u", user, "-p", pw, "-j", "-t", sql], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no sap hana indexserver reachable: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows = _hana_rows(res.stdout)
    host_part = item.split(" - ")[1] if " - " in item else ""
    match = None
    for r in rows:
        if r.get("HOST", "") == host_part:
            match = r
            break
    if match == None:
        return {"changed": False, "msg": "sap hana instance not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sql2 = "SELECT HOST, PORT, SQL_ADDRESS, SQL_PORT FROM M_DISK_USAGE"
    res2 = ctx.run(["hdbsql", "-n", host + ":" + hana_port, "-u", user, "-p", pw, "-j", "-t", sql2], mutates=False)
    if res2.rc != 0 or not res2.stdout.strip():
        return {"changed": False, "msg": "no sap hana disk usage data for: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    du = _hana_rows(res2.stdout)
    size_mb = 0.0
    used_mb = 0.0
    ok = False
    for d in du:
        if d.get("HOST", "") == match.get("HOST", ""):
            size_mb = float(d.get("size", 0))
            used_mb = float(d.get("used", 0))
            ok = True
    if not ok:
        return {"changed": False, "msg": "no disk usage entry for: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    avail_mb = size_mb - used_mb
    used_percent = 0.0
    if size_mb > 0:
        used_percent = (used_mb / size_mb) * 100

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"

    return {"changed": False, "msg": "used %s of %s GB (%d%%)" % (_fmt(used_mb), _fmt(size_mb), used_percent),
            "data": {"state": state, "metrics": {"used_percent": used_percent, "size": size_mb, "used": used_mb, "avail": avail_mb}, "details": ""}}


def _hana_rows(stdout):
    lines = stdout.strip().splitlines()
    rows = []
    for ln in lines:
        if ln.startswith("|"):
            continue
        if "SQL error" in ln or "error" in ln.lower():
            continue
        parts = ln.split("\t")
        if len(parts) < 4:
            continue
        rows.append({"HOST": parts[0], "PORT": parts[1], "SQL_ADDRESS": parts[2], "SQL_PORT": parts[3]})
    return rows


def _fmt(v):
    return "%f" % v