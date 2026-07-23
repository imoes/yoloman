def main(ctx, params):
    if params.get("_discover"):
        # Discover PostgreSQL databases by running psql to list active databases
        # Assume pg_isready and psql are available on the host
        # Use psql -lqt to list databases in a parseable format (name only)
        res = ctx.run(["psql", "-lqt"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to list databases", 
                    "data": {"discovery": []}}
        
        databases = []
        for line in res.stdout.splitlines():
            name = line.strip()
            if name:  # skip empty lines
                databases.append({"item": name, "params": {}, "metrics": ["shared_locks", "exclusive_locks"]})
        
        return {"changed": False, "msg": "discovered %d databases" % len(databases),
                "data": {"discovery": databases}}

    # Check mode: check one item (database)
    item = params.get("item", "")
    if not item:
        fail("item (database name) is required for check mode")

    # Run psql to get lock status for the specific database
    # Query: get granted locks grouped by mode for the given database
    # Use \pset format=aligned to get consistent parsing; but simpler to use CSV
    # psql -d <db> -t -F';' -c "SELECT granted, mode FROM pg_locks WHERE database = (SELECT oid FROM pg_database WHERE datname = 'db') ORDER BY granted, mode;"
    query = "SELECT granted, mode FROM pg_locks WHERE database = (SELECT oid FROM pg_database WHERE datname = '%s') ORDER BY granted, mode;" % item.replace("'", "''")
    res = ctx.run(["psql", "-d", item, "-t", "-F;", "-c", query], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "failed to query locks for database %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse CSV-like output: each line is "granted;mode"
    locks = {"AccessShareLock": 0, "ExclusiveLock": 0}
    for line in res.stdout.splitlines():
        fields = line.strip().split(";")
        if len(fields) >= 2:
            granted_str = fields[0].strip()
            mode = fields[1].strip()
            if mode and granted_str.lower() == "t":  # granted is 't' for true
                if mode in locks:
                    locks[mode] += 1
                else:
                    locks[mode] = 1

    shared_locks = locks.get("AccessShareLock", 0)
    exclusive_locks = locks.get("ExclusiveLock", 0)

    # Determine state
    state = "OK"
    details_parts = []

    # Check shared locks
    if params.get("levels_shared"):
        warn, crit = params["levels_shared"]
        if shared_locks >= crit:
            state = "CRIT"
        elif shared_locks >= warn and state != "CRIT":
            state = "WARN"
        details_parts.append("Access Share Locks %d (levels: %d/%d)" % (shared_locks, warn, crit))
    else:
        details_parts.append("Access Share Locks %d" % shared_locks)

    # Check exclusive locks
    if params.get("levels_exclusive"):
        warn, crit = params["levels_exclusive"]
        if exclusive_locks >= crit:
            state = "CRIT"
        elif exclusive_locks >= warn and state != "CRIT":
            state = "WARN"
        details_parts.append("Exclusive Locks %d (levels: %d/%d)" % (exclusive_locks, warn, crit))
    else:
        details_parts.append("Exclusive Locks %d" % exclusive_locks)

    # Build message
    msg = ", ".join(details_parts)

    return {"changed": False, "msg": msg,
            "data": {"state": state, 
                     "metrics": {"shared_locks": shared_locks, "exclusive_locks": exclusive_locks},
                     "details": ""}}