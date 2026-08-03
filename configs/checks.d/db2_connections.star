# Checkmk check: db2_connections — translated to read-only Starlark
# Monitors DB2 instance connections and latency via on-host DB2 CLI tools.

def main(ctx, params):
    # --- Discovery mode: probe for the real DB2 tooling, enumerate instances ---
    if params.get("_discover"):
        # Probe for the real DB2 product presence first.
        version_res = ctx.run(["db2", "-v"], mutates=False)
        if version_res.rc != 0 or not version_res.stdout:
            return {"changed": False, "msg": "no DB2 instance found", "data": {"discovery": []}}

        # Discover DB2 database instances via the official listing command.
        list_res = ctx.run(["db2", "list", "db", "directory"], mutates=False)
        instances = []
        if list_res.rc == 0:
            for line in list_res.stdout.splitlines():
                s = line.strip()
                # Lines like "DatabaseName  = MYDB" identify the database (instance item).
                if s.startswith("DatabaseName") and "=" in s:
                    val = s.split("=", 1)[1].strip()
                    if val and val not in instances:
                        instances.append(val)

        discovery = []
        for item in instances:
            levels = params.get("levels_total", (150, 200))
            warn = levels[0] if len(levels) >= 1 else 150
            crit = levels[1] if len(levels) >= 2 else 200
            discovery.append({
                "item": item,
                "params": {"levels_total": [warn, crit]},
                "metrics": ["connections", "latency"],
            })

        return {
            "changed": False,
            "msg": "discovered %d DB2 instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- Check mode: gather data for one item, apply thresholds ---
    item = params.get("item", "")
    levels_total = params.get("levels_total", (150, 200))
    warn = levels_total[0] if len(levels_total) >= 1 else 150
    crit = levels_total[1] if len(levels_total) >= 2 else 200

    # Probe for DB2 presence; absence is an answer, never OK.
    version_res = ctx.run(["db2", "-v"], mutates=False)
    if version_res.rc != 0 or not version_res.stdout:
        return {
            "changed": False,
            "msg": "no DB2 instance found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "DB2 client (db2) not installed or not running"},
        }

    # Gather connection count for this database (instance).
    # 'db2 get snapshot for dbm' reports the number of applications connected.
    connect_res = ctx.run(
        ["db2", "get", "snapshot", "for", "dbm"], mutates=False,
    )
    connections = 0
    got_connections = False
    if connect_res.rc == 0:
        for line in connect_res.stdout.splitlines():
            s = line.strip().lower()
            if "applications connected to database" in s or "applications connected" in s:
                # Line format: "Applications connected to database = N"
                if "=" in line:
                    val = line.split("=", 1)[1].strip()
                    if val.isdigit():
                        connections = int(val)
                        got_connections = True
                        break

    if not got_connections:
        return {
            "changed": False,
            "msg": "could not retrieve connection count for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no connection data available"},
        }

    # Threshold grading: upper levels -> WARN if >= warn, CRIT if >= crit.
    if connections >= crit:
        state = "CRIT"
    elif connections >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Gather latency information if available via db2pd or snapshot.
    latency_ms = None
    latency_res = ctx.run(
        ["db2", "get", "snapshot", "for", "db", item], mutates=False,
    )
    if latency_res.rc == 0:
        for line in latency_res.stdout.splitlines():
            sl = line.strip().lower()
            if "total latency" in sl or "average latency" in sl or "latency" in sl and "=" in line:
                if "=" in line:
                    val = line.split("=", 1)[1].strip()
                    # Try to parse a numeric latency value.
                    if val.isdigit():
                        latency_ms = int(val)
                        break
                    # Handle old time format 'min:seconds.milliseconds'
                    if ":" in val:
                        minutes_str, rest = val.split(":", 1)
                        mparts = rest.split(",") if "," in rest else rest.split(".")
                        ms = 0
                        if mparts[0].isdigit():
                            ms = int(mparts[0]) * 1000
                        if len(mparts) > 1 and mparts[1].isdigit():
                            ms += int(mparts[1])
                        if minutes_str.isdigit():
                            ms += int(minutes_str) * 60 * 1000
                        latency_ms = ms
                        break

    # Build metrics (plain numbers only).
    metrics = {"connections": connections}
    if latency_ms != None:
        metrics["latency"] = latency_ms

    # Build the Checkmk-style summary message.
    msg_parts = ["Connections: %d" % connections]
    if latency_ms != None:
        msg_parts.append("Latency: %f ms" % (latency_ms / 1.0))
    msg = ", ".join(msg_parts)

    details = ""
    if latency_ms != None:
        details = "Latency: %f ms" % (latency_ms / 1.0)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }