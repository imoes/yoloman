def main(ctx, params):
    if params.get("_discover"):
        find_res = ctx.run(
            ["find", "/home", "-maxdepth", "3", "-name", "db2profile"],
            mutates=False, ok_codes=[0, 1]
        )
        items = []
        for profile_path in find_res.stdout.splitlines():
            profile_path = profile_path.strip()
            if not profile_path or "sqllib/db2profile" not in profile_path:
                continue
            path_parts = profile_path.split("/")
            if len(path_parts) < 4:
                continue
            instance = path_parts[2]
            db_list_res = ctx.run(
                ["su", "-", instance, "-c", "db2 list db directory 2>/dev/null"],
                mutates=False, ok_codes=[0, 1, 2]
            )
            current_alias = None
            for line in db_list_res.stdout.splitlines():
                line = line.strip()
                if line.startswith("Database alias"):
                    kv = line.split("=", 1)
                    if len(kv) == 2:
                        current_alias = kv[1].strip()
                elif line.startswith("Directory entry type") and current_alias != None:
                    kv = line.split("=", 1)
                    entry_type = kv[1].strip() if len(kv) == 2 else ""
                    if entry_type != "Remote":
                        items.append({
                            "item": instance + ":" + current_alias,
                            "params": {"levels_total": [150, 200]},
                            "metrics": ["connections"],
                        })
                    current_alias = None
        return {
            "changed": False,
            "msg": "discovered %d DB2 databases" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    colon_idx = item.find(":")
    if colon_idx < 0:
        return {
            "changed": False,
            "msg": "invalid item (expected instance:database): " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    instance = item[:colon_idx]
    database = item[colon_idx + 1:]

    levels = params.get("levels_total", None)
    if levels != None and len(levels) == 2:
        warn_conn = levels[0]
        crit_conn = levels[1]
    else:
        warn_conn = params.get("warn", 150)
        crit_conn = params.get("crit", 200)

    # Resolve port: SVCENAME in DBM config may be a service name or a number
    port = "unknown"
    port_res = ctx.run(
        ["su", "-", instance, "-c", "db2 get dbm cfg 2>/dev/null"],
        mutates=False, ok_codes=[0, 1]
    )
    for line in port_res.stdout.splitlines():
        if "SVCENAME" in line.upper() and "=" in line:
            kv = line.split("=", 1)
            svc = kv[1].strip().split()[0] if (len(kv) == 2 and kv[1].strip()) else ""
            if svc:
                port = svc
            break

    if port != "unknown" and not port.isdigit():
        svc_res = ctx.run(
            ["grep", "-w", port, "/etc/services"],
            mutates=False, ok_codes=[0, 1]
        )
        for line in svc_res.stdout.splitlines():
            svc_parts = line.split()
            if len(svc_parts) >= 2 and "/" in svc_parts[1]:
                port = svc_parts[1].split("/")[0]
                break

    # Query active connection count; su -c runs through login shell so db2 is on PATH
    query_cmd = (
        "db2 connect to " + database + " > /dev/null 2>&1 && " +
        "db2 -x \"SELECT COUNT(*) FROM SYSIBMADM.APPLICATIONS WHERE DB_NAME=CURRENT SERVER\" && " +
        "db2 disconnect all > /dev/null 2>&1"
    )
    conn_res = ctx.run(
        ["su", "-", instance, "-c", query_cmd],
        mutates=False, ok_codes=[0, 1, 2]
    )

    conn_count = None
    for line in conn_res.stdout.splitlines():
        stripped = line.strip()
        if stripped.isdigit():
            conn_count = int(stripped)
            break

    if conn_count == None:
        return {
            "changed": False,
            "msg": "Login into database failed: " + database,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": conn_res.stderr[:200]},
        }

    state = "CRIT" if conn_count >= crit_conn else ("WARN" if conn_count >= warn_conn else "OK")

    return {
        "changed": False,
        "msg": "Connections: %d, Port: %s" % (conn_count, port),
        "data": {
            "state": state,
            "metrics": {"connections": conn_count},
            "details": "",
        },
    }