def main(ctx, params):
    host = params.get("host", "localhost")
    instance = params.get("instance", "MSSQLSERVER")
    port = params.get("port", 1433)
    user = params.get("user", "")
    password = params.get("password", "")

    if instance != "" and instance != "MSSQLSERVER":
        server = host + "\\" + instance
    else:
        server = host
    if port != 1433:
        server = host + "," + str(port)

    query = "SET NOCOUNT ON; SELECT DB_NAME(dbid), COUNT(dbid) FROM sys.sysprocesses WHERE dbid > 0 GROUP BY dbid"
    argv = ["sqlcmd", "-S", server, "-Q", query, "-h", "-1", "-W"]
    if user != "":
        argv = argv + ["-U", user, "-P", password]
    else:
        argv = argv + ["-E"]

    res = ctx.run(argv, mutates=False, ok_codes=[0, 1])

    if params.get("_discover"):
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "sqlcmd failed: " + res.stderr,
                "data": {"discovery": []},
            }
        items = []
        for raw in res.stdout.splitlines():
            line = raw.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) < 2 or not parts[1].isdigit():
                continue
            db_name = parts[0]
            items.append({
                "item": instance + " " + db_name,
                "params": {"levels": ["no_levels", None]},
                "metrics": ["connections"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    space = item.find(" ")
    if space < 0:
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    db_name = item[space + 1:]

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "sqlcmd failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    connections = -1
    for raw in res.stdout.splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[0] == db_name and parts[1].isdigit():
            connections = int(parts[1])
            break

    if connections < 0:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    levels = params.get("levels", ["no_levels", None])
    state = "OK"
    if levels[0] == "fixed" and levels[1] != None:
        warn = levels[1][0]
        crit = levels[1][1]
        if connections >= crit:
            state = "CRIT"
        elif connections >= warn:
            state = "WARN"

    return {
        "changed": False,
        "msg": "Connections: %d" % connections,
        "data": {
            "state": state,
            "metrics": {"connections": connections},
            "details": "",
        },
    }