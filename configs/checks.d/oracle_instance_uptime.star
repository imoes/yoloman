def main(ctx, params):
    # Probe for the real data source: sqlplus binary
    probe = ctx.run(["which", "sqlplus"], mutates=False)
    if probe.rc != 0:
        return {"changed": False, "msg": "sqlplus not found",
                "data": {"discovery": [], "host_labels": {}}}

    if params.get("_discover"):
        # Discovery: enumerate Oracle instances with uptime
        discovery = []
        res = ctx.run(
            ["sqlplus", "-s", "/", "as", "sysdba", "@-", "<<<END_SQL",
             "SET HEADING OFF",
             "SET FEEDBACK OFF",
             "SELECT INSTANCE_NAME, UPTIME FROM V$INSTANCE;",
             "EXIT",
             "END_SQL"],
            mutates=False
        )
        if res.rc == 0:
            lines = res.stdout.splitlines()
            for line in lines:
                parts = line.split()
                if len(parts) >= 2:
                    instance_name = parts[0]
                    uptime_str = parts[1]
                    up_seconds = int(uptime_str) if uptime_str.isdigit() else -1
                    if up_seconds != None and up_seconds != -1:
                        discovery.append({
                            "item": instance_name,
                            "params": {"min": None, "max": None},
                            "metrics": ["uptime"]
                        })
        return {"changed": False, "msg": "discovered %d instances" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {}}}

    item = params.get("item", "")
    # Check mode: get uptime for specific instance
    res = ctx.run(
        ["sqlplus", "-s", "/", "as", "sysdba", "@-", "<<<END_SQL",
         "SET HEADING OFF",
         "SET FEEDBACK OFF",
         "SELECT INSTANCE_NAME, UPTIME FROM V$INSTANCE WHERE INSTANCE_NAME = '%s';" % item,
         "EXIT",
         "END_SQL"],
        mutates=False
    )

    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no data for instance %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Could not retrieve instance data"}}

    lines = res.stdout.splitlines()
    up_seconds = None
    for line in lines:
        parts = line.split()
        if len(parts) >= 2 and parts[0] == item:
            up_seconds_str = parts[1]
            up_seconds = int(up_seconds_str) if up_seconds_str.isdigit() else None
            break

    if up_seconds == None:
        return {"changed": False, "msg": "instance %s not found or invalid data" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Instance data unavailable"}}

    if up_seconds < 0:
        return {"changed": False, "msg": "Uptime: invalid negative value (%ds)" % up_seconds,
                "data": {"state": "WARN", "metrics": {}, "details": "Invalid uptime value"}}

    # Apply thresholds from checkmk uptime_multiitem levels
    min_levels = params.get("min", None)
    max_levels = params.get("max", None)

    state = "OK"
    up_since = ctx.run(["date", "+%s"], mutates=False)
    current_time = int(up_since.stdout) if up_since.stdout and up_since.stdout.strip().isdigit() else 0
    details = "Up since: %d seconds ago" % (current_time - up_seconds)

    # Apply lower thresholds (warn, crit)
    if min_levels:
        warn_lower, crit_lower = min_levels
        if crit_lower != None and up_seconds <= crit_lower:
            state = "CRIT"
        elif warn_lower != None and up_seconds <= warn_lower:
            state = "WARN"

    # Apply upper thresholds (warn, crit)
    if max_levels:
        warn_upper, crit_upper = max_levels
        if crit_upper != None and up_seconds >= crit_upper:
            state = "CRIT"
        elif warn_upper != None and up_seconds >= warn_upper:
            state = "WARN"

    metrics = {"uptime": up_seconds}
    msg = "Up for %d seconds" % up_seconds

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}