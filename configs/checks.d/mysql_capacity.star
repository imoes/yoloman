SKIP_DBS = ["information_schema", "performance_schema", "mysql"]

def _fmt_bytes(n):
    if n >= 1073741824:
        return "%f GB" % (n / 1073741824.0)
    if n >= 1048576:
        return "%f MB" % (n / 1048576.0)
    if n >= 1024:
        return "%f kB" % (n / 1024.0)
    return "%d B" % n

def _mysql_cmd(params):
    cmd = ["mysql", "--batch", "--skip-column-names"]
    cmd += ["-u", params.get("user", "root")]
    pw = params.get("password")
    if pw != None:
        cmd += ["--password=" + pw]
    sock = params.get("socket")
    if sock != None:
        cmd += ["--socket=" + sock]
    else:
        cmd += ["-h", params.get("host", "localhost"),
                "-P", str(params.get("port", 3306))]
    return cmd

def _query_sizes(ctx, params):
    sql = "SELECT table_schema, COALESCE(SUM(data_length + index_length), 0) FROM information_schema.TABLES GROUP BY table_schema"
    res = ctx.run(_mysql_cmd(params) + ["-e", sql], mutates=False)
    if res.rc != 0:
        return None
    sizes = {}
    for line in res.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        dbname = parts[0].strip()
        val = parts[1].strip()
        if val == "" or val == "NULL":
            continue
        sizes[dbname] = int(float(val))
    return sizes

def main(ctx, params):
    instance = params.get("instance", "mysql")

    if params.get("_discover"):
        sizes = _query_sizes(ctx, params)
        if sizes == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        items = []
        for dbname in sorted(sizes.keys()):
            if dbname in SKIP_DBS:
                continue
            items.append({
                "item": instance + ":" + dbname,
                "params": {},
                "metrics": ["database_size"],
            })
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    parts = item.split(":", 1)
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    dbname = parts[1]

    sizes = _query_sizes(ctx, params)
    if sizes == None:
        return {"changed": False, "msg": "MySQL query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if dbname not in sizes:
        return {"changed": False, "msg": "database not found: " + dbname,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    size = sizes[dbname]

    levels = params.get("levels")
    if levels != None:
        warn = levels[0]
        crit = levels[1]
    else:
        warn = params.get("warn")
        crit = params.get("crit")

    state = "OK"
    if crit != None and size >= crit:
        state = "CRIT"
    elif warn != None and size >= warn:
        state = "WARN"

    return {"changed": False, "msg": "Size: " + _fmt_bytes(size),
            "data": {"state": state, "metrics": {"database_size": size}, "details": ""}}