def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["psql", "--version"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "psql not found", "data": {"discovery": []}}
        if probe.rc != 0:
            return {"changed": False, "msg": "psql not available", "data": {"discovery": []}}
        max_res = ctx.run(["psql", "-t", "-A", "-c", "SHOW max_connections"], mutates=False)
        if max_res.rc != 0:
            return {"changed": False, "msg": "cannot connect to PostgreSQL", "data": {"discovery": []}}
        max_conn = max_res.stdout.strip()
        query = "SELECT datname, count(*) FILTER (WHERE state = 'active'), count(*) FILTER (WHERE state = 'idle'), count(*) FROM pg_stat_activity GROUP BY datname"
        res = ctx.run(["psql", "-t", "-A", "-F|", "-c", query], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "psql query failed", "data": {"discovery": []}}
        databases = {}
        for line in res.stdout.strip().split("\n"):
            parts = line.split("|")
            if len(parts) >= 5:
                datname = parts[0].strip()
                if datname and datname != "datname":
                    databases[datname] = {
                        "active": int(parts[1].strip()) if parts[1].strip().isdigit() else 0,
                        "idle": int(parts[2].strip()) if parts[2].strip().isdigit() else 0,
                        "current": int(parts[3].strip()) if parts[3].strip().isdigit() else 0,
                        "mc": float(max_conn) if max_conn else 100.0,
                    }
        if not databases:
            return {"changed": False, "msg": "no databases found", "data": {"discovery": []}}
        discovery = []
        for db_name in databases:
            discovery.append({
                "item": db_name,
                "params": {
                    "levels_perc_active": (80.0, 90.0),
                    "levels_perc_idle": (80.0, 90.0),
                },
                "metrics": ["active_connections", "idle_connections"],
            })
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    probe = ctx.run(["psql", "--version"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "psql not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "psql client not installed"}}
    max_res = ctx.run(["psql", "-t", "-A", "-c", "SHOW max_connections"], mutates=False)
    if max_res.rc != 0:
        return {"changed": False, "msg": "cannot connect to PostgreSQL", "data": {"state": "UNKNOWN", "metrics": {}, "details": "cannot connect to PostgreSQL"}}
    max_conn = max_res.stdout.strip()
    query = "SELECT datname, count(*) FILTER (WHERE state = 'active'), count(*) FILTER (WHERE state = 'idle'), count(*) FROM pg_stat_activity WHERE datname = '%s' GROUP BY datname" % item
    res = ctx.run(["psql", "-t", "-A", "-F|", "-c", query], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "psql query failed for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "query failed"}}
    databases = {}
    for line in res.stdout.strip().split("\n"):
        parts = line.split("|")
        if len(parts) >= 5:
            datname = parts[0].strip()
            if datname and datname != "datname":
                databases[datname] = {
                    "active": int(parts[1].strip()) if parts[1].strip().isdigit() else 0,
                    "idle": int(parts[2].strip()) if parts[2].strip().isdigit() else 0,
                    "current": int(parts[3].strip()) if parts[3].strip().isdigit() else 0,
                    "mc": float(max_conn) if max_conn else 100.0,
                }
    if item not in databases:
        return {"changed": False, "msg": "no connections for database %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "database not found or no connections"}}
    db = databases[item]
    maximum = db["mc"]
    active = db["active"]
    idle = db["idle"]
    metrics = {}
    details_parts = []
    warn_active_levels = params.get("levels_perc_active", (80.0, 90.0))
    warn_active = warn_active_levels[0]
    crit_active = warn_active_levels[1]
    warn_idle_levels = params.get("levels_perc_idle", (80.0, 90.0))
    warn_idle = warn_idle_levels[0]
    crit_idle = warn_idle_levels[1]
    state = "OK"
    metrics["active_connections"] = active
    if maximum > 0:
        used_perc_active = active / maximum * 100
        if used_perc_active >= crit_active:
            state = "CRIT"
        elif used_perc_active >= warn_active:
            if state != "CRIT":
                state = "WARN"
        details_parts.append("Active: %d (%f%%)" % (active, used_perc_active))
    if idle != None:
        metrics["idle_connections"] = idle
        if maximum > 0:
            used_perc_idle = idle / maximum * 100
            if used_perc_idle >= crit_idle:
                state = "CRIT"
            elif used_perc_idle >= warn_idle:
                if state != "CRIT":
                    state = "WARN"
            details_parts.append("Idle: %d (%f%%)" % (idle, used_perc_idle))
    msg = "database %s: " % item + ", ".join(details_parts) if details_parts else "database %s" % item
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": ", ".join(details_parts)}}