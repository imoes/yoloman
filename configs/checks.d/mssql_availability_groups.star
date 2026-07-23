SYNC_STATE_MAP = {
    "HEALTHY": "OK",
    "NOT_HEALTHY": "CRIT",
    "PARTIALLY_HEALTHY": "WARN",
}

_QUERY = (
    "SET NOCOUNT ON; " +
    "SELECT ag.name + '|' + ISNULL(ags.primary_replica, '') + '|' + " +
    "ISNULL(ags.synchronization_health_desc, 'UNKNOWN') " +
    "FROM sys.availability_groups ag " +
    "JOIN sys.dm_hadr_availability_group_states ags " +
    "ON ags.group_id = ag.group_id;"
)


def _server_str(host, port, instance):
    server = host
    if instance != None and instance != "":
        server = host + "\\" + instance
    port_int = int(port)
    if port_int != 1433:
        server = server + "," + str(port_int)
    return server


def _run_query(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 1433)
    user = params.get("user", "")
    password = params.get("password", "")
    instance = params.get("instance", "")
    server = _server_str(host, port, instance)
    cmd = ["sqlcmd", "-S", server, "-h", "-1", "-W", "-Q", _QUERY]
    if user != None and user != "":
        cmd = cmd + ["-U", user, "-P", password]
    else:
        cmd = cmd + ["-E"]
    return ctx.run(cmd, mutates=False)


def _parse_rows(stdout):
    rows = []
    for line in stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        parts = line.split("|")
        if len(parts) < 3:
            continue
        rows.append({
            "name": parts[0].strip(),
            "primary": parts[1].strip(),
            "sync": parts[2].strip(),
        })
    return rows


def main(ctx, params):
    if params.get("_discover"):
        res = _run_query(ctx, params)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "sqlcmd failed: " + res.stderr.strip(),
                "data": {"discovery": []},
            }
        rows = _parse_rows(res.stdout)
        discovery = [
            {"item": r["name"], "params": {}, "metrics": []}
            for r in rows
            if r["name"] != ""
        ]
        return {
            "changed": False,
            "msg": "discovered %d availability groups" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    res = _run_query(ctx, params)

    if res.rc != 0:
        err = res.stderr.strip()
        if err == "":
            err = res.stdout.strip()
        return {
            "changed": False,
            "msg": "sqlcmd failed: " + err,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lines = res.stdout.splitlines()
    if len(lines) > 0:
        first = lines[0].strip()
        err_idx = first.find(" ERROR: ")
        if (err_idx >= 0) and ("|" not in first):
            inst = first[:err_idx]
            msg = first[err_idx + 8:]
            return {
                "changed": False,
                "msg": "Error from instance %s: %s" % (inst, msg),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    rows = _parse_rows(res.stdout)
    for r in rows:
        if r["name"] != item:
            continue
        sync = r["sync"]
        state = SYNC_STATE_MAP.get(sync, "UNKNOWN")
        return {
            "changed": False,
            "msg": "Primary replica: %s, Synchronization state: %s" % (r["primary"], sync),
            "data": {"state": state, "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "Availability group not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }