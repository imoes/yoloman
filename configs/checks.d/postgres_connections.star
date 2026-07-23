# PostgreSQL Connections check module for yolo-man agent
# Translated from Checkmk plugin cmk.plugins.postgres.postgres_connections

# Threshold defaults per connection type
DEFAULT_LEVELS_PERC = {"active": (80.0, 90.0), "idle": (80.0, 90.0)}

def main(ctx, params):
    if params.get("_discover"):
        # Gather databases by running the same command the Checkmk agent would run
        # For PostgreSQL, the checkmk agent uses pg_isready + psql to get connection counts
        # We use psql directly since we have no Checkmk agent
        # Command: psql -U postgres -c "SELECT datname, count(*) FILTER (WHERE state='active') as active,
        #                     count(*) FILTER (WHERE state='idle') as idle,
        #                     pg_database.datconnlimit as maxconn
        #                     FROM pg_stat_activity, pg_database
        #                     WHERE pg_stat_activity.datname = pg_database.datname
        #                     GROUP BY datname, pg_database.datconnlimit;"
        
        # Try psql with default settings first, fall back to common alternatives
        psql_cmd = None
        for cmd in [
            ["psql", "-U", "postgres", "-c", 
             "SELECT datname, count(*) FILTER (WHERE state='active') as active, " +
             "count(*) FILTER (WHERE state='idle') as idle, " +
             "pg_database.datconnlimit as maxconn FROM pg_stat_activity, pg_database " +
             "WHERE pg_stat_activity.datname = pg_database.datname " +
             "GROUP BY datname, pg_database.datconnlimit;"],
            ["psql", "-c", 
             "SELECT datname, count(*) FILTER (WHERE state='active') as active, " +
             "count(*) FILTER (WHERE state='idle') as idle, " +
             "pg_database.datconnlimit as maxconn FROM pg_stat_activity, pg_database " +
             "WHERE pg_stat_activity.datname = pg_database.datname " +
             "GROUP BY datname, pg_database.datconnlimit;"],
        ]:
            res = ctx.run(cmd, mutates=False)
            if res.rc == 0 and len(res.stdout.strip()) > 0:
                psql_cmd = cmd
                break
        
        if psql_cmd == None:
            return {
                "changed": False,
                "msg": "discovered 0 databases (psql not available or failed)",
                "data": {"discovery": []}
            }
        
        # Parse psql output (header, separator, data rows)
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {
                "changed": False,
                "msg": "discovered 0 databases (empty output)",
                "data": {"discovery": []}
            }
        
        databases = []
        for line in lines[2:]:  # Skip header and separator lines
            fields = line.split("|")
            if len(fields) < 4:
                continue
            datname = fields[0].strip()
            active = int(fields[1].strip()) if fields[1].strip().isdigit() else 0
            idle = int(fields[2].strip()) if fields[2].strip().isdigit() else 0
            maxconn = int(fields[3].strip()) if fields[3].strip().isdigit() else 100
            
            if datname == "" or datname == "(0 rows)":
                continue
            
            # Only include if we have valid data
            databases.append({
                "item": datname,
                "params": {
                    "levels_abs_active": (None, None),
                    "levels_abs_idle": (None, None),
                    "levels_perc_active": DEFAULT_LEVELS_PERC["active"],
                    "levels_perc_idle": DEFAULT_LEVELS_PERC["idle"],
                },
                "metrics": ["active_connections", "idle_connections"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d databases" % len(databases),
            "data": {"discovery": databases}
        }
    
    # Check mode - examine one database
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no database item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get database connection counts via psql
    psql_cmd = None
    for cmd in [
        ["psql", "-U", "postgres", "-c", 
         "SELECT count(*) FILTER (WHERE state='active') as active, " +
         "count(*) FILTER (WHERE state='idle') as idle, " +
         "pg_database.datconnlimit as maxconn FROM pg_stat_activity, pg_database " +
         "WHERE pg_stat_activity.datname = pg_database.datname AND pg_database.datname = '" + item + "';"],
        ["psql", "-c", 
         "SELECT count(*) FILTER (WHERE state='active') as active, " +
         "count(*) FILTER (WHERE state='idle') as idle, " +
         "pg_database.datconnlimit as maxconn FROM pg_stat_activity, pg_database " +
         "WHERE pg_stat_activity.datname = pg_database.datname AND pg_database.datname = '" + item + "';"],
    ]:
        res = ctx.run(cmd, mutates=False)
        if res.rc == 0:
            psql_cmd = cmd
            break
    
    if psql_cmd == None:
        return {
            "changed": False,
            "msg": "psql command failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "no data for database %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse result - format: active|idle|maxconn
    fields = lines[1].split("|")
    if len(fields) < 3:
        return {
            "changed": False,
            "msg": "invalid output format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    active = int(fields[0].strip()) if fields[0].strip().isdigit() else 0
    idle = int(fields[1].strip()) if fields[1].strip().isdigit() else 0
    maxconn = int(fields[2].strip()) if fields[2].strip().isdigit() else 100
    
    # Apply thresholds
    levels_abs_active = params.get("levels_abs_active", (None, None))
    levels_abs_idle = params.get("levels_abs_idle", (None, None))
    levels_perc_active = params.get("levels_perc_active", DEFAULT_LEVELS_PERC["active"])
    levels_perc_idle = params.get("levels_perc_idle", DEFAULT_LEVELS_PERC["idle"])
    
    # Calculate percentages
    active_perc = (float(active) / float(maxconn) * 100.0) if maxconn > 0 else 0.0
    idle_perc = (float(idle) / float(maxconn) * 100.0) if maxconn > 0 else 0.0
    
    # Determine states
    state = "OK"
    details = []
    
    # Active connections check
    if active > 0 or idle > 0:
        # Active percentage
        if levels_perc_active[1] != None and active_perc >= levels_perc_active[1]:
            state = "CRIT"
        elif levels_perc_active[0] != None and active_perc >= levels_perc_active[0]:
            state = "WARN" if state != "CRIT" else state
        
        # Idle percentage
        if levels_perc_idle[1] != None and idle_perc >= levels_perc_idle[1]:
            state = "CRIT"
        elif levels_perc_idle[0] != None and idle_perc >= levels_perc_idle[0]:
            state = "WARN" if state != "CRIT" else state
        
        # Active absolute
        if levels_abs_active[1] != None and active >= levels_abs_active[1]:
            state = "CRIT"
        elif levels_abs_active[0] != None and active >= levels_abs_active[0]:
            state = "WARN" if state != "CRIT" else state
        
        # Idle absolute
        if levels_abs_idle[1] != None and idle >= levels_abs_idle[1]:
            state = "CRIT"
        elif levels_abs_idle[0] != None and idle >= levels_abs_idle[0]:
            state = "WARN" if state != "CRIT" else state
    
    # Build summary message
    if maxconn > 0:
        details.append("active: %d/%d (%d%%)" % (active, maxconn, int(active_perc)))
        if idle >= 0:
            details.append("idle: %d (%d%%)" % (idle, int(idle_perc)))
    else:
        details.append("active: %d" % active)
        if idle >= 0:
            details.append("idle: %d" % idle)
    
    return {
        "changed": False,
        "msg": "%s" % "; ".join(details),
        "data": {
            "state": state,
            "metrics": {
                "active_connections": active,
                "idle_connections": idle,
                "active_connections_percent": active_perc,
                "idle_connections_percent": idle_perc,
            },
            "details": "; ".join(details),
        },
    }