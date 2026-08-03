# MySQL DB Size check — translated from Checkmk checkmk.mysql_capacity
# Reads database sizes directly from MySQL via the mysql client, replicating
# what the Checkmk MySQL agent plugin would collect (information_schema).

def _run_mysql_query(ctx, args):
    """Run a mysql client query, returning (rc, stdout, stderr)."""
    res = ctx.run(args, mutates=False)
    return res.rc, res.stdout, res.stderr

def _mysql_instances(ctx):
    """Find MySQL instances by probing for mysqld.
    Returns list of instance descriptors: {"host", "user", "password"}.
    """
    instances = []
    # Probe if MySQL client is available
    probe = ctx.run(["mysql", "--version"], mutates=False)
    if probe.rc == 127:
        return []
    # Check for a running mysqld process
    ps = ctx.run(["pgrep", "-x", "mysqld"], mutates=False)
    if ps.rc != 0 and ps.rc != 1:
        # No mysqld running found
        return []
    # Single instance assumed: localhost
    # Try to read auth from standard config files
    user = "root"
    password = ""
    # Check /root/.my.cnf for credentials (common Checkmk setup)
    cnf = ctx.file_read("/root/.my.cnf") if ctx.file_exists("/root/.my.cnf") else ""
    if cnf:
        for line in cnf.split("\n"):
            line = line.strip()
            if line.startswith("user") and "=" in line:
                user = line.split("=", 1)[1].strip()
            elif line.startswith("password") and "=" in line:
                password = line.split("=", 1)[1].strip()
    instances.append({"host": "localhost", "user": user, "password": password})
    return instances

def _query_db_sizes(ctx, instance):
    """Query MySQL for database sizes via information_schema.
    Returns dict: {dbname: size_in_bytes} or None on failure.
    """
    host = instance["host"]
    user = instance["user"]
    password = instance["password"]
    
    # Build mysql client command
    cmd = [
        "mysql",
        "--host=%s" % host,
        "--user=%s" % user,
        "--batch",
        "--skip-column-names",
        "--table",
        "-e",
        "SELECT table_schema, SUM(data_length + index_length) AS total_size FROM information_schema.tables WHERE table_schema IS NOT NULL GROUP BY table_schema",
    ]
    if password:
        cmd.insert(3, "--password=%s" % password)
    
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return None
    
    sizes = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) >= 2:
            dbname = " ".join(parts[:-1])
            size_str = parts[-1]
            if size_str.isdigit():
                sizes[dbname] = int(size_str)
    return sizes

def _bytes_to_human(size_bytes):
    """Convert bytes to human-readable string (like render.bytes)."""
    if size_bytes < 1024:
        return "%d B" % size_bytes
    elif size_bytes < 1024 * 1024:
        return "%f KB" % (size_bytes / 1024.0)
    elif size_bytes < 1024 * 1024 * 1024:
        return "%f MB" % (size_bytes / (1024.0 * 1024))
    else:
        return "%f GB" % (size_bytes / (1024.0 * 1024 * 1024))

def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        instances = _mysql_instances(ctx)
        discovery = []
        for inst in instances:
            sizes = _query_db_sizes(ctx, inst)
            if sizes == None:
                continue
            for dbname in sizes:
                if dbname in ["information_schema", "performance_schema", "mysql", "sys"]:
                    continue
                instance_label = "localhost"
                item = "%s:%s" % (instance_label, dbname)
                discovery.append({
                    "item": item,
                    "params": {"levels": params.get("levels", None)},
                    "metrics": ["database_size"],
                })
        count = len(discovery)
        return {
            "changed": False,
            "msg": "discovered %d MySQL databases" % count,
            "data": {"discovery": discovery},
        }
    
    # --- CHECK MODE ---
    item = params.get("item", "")
    if item == "" or item == None:
        return {
            "changed": False,
            "msg": "no MySQL database item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no item specified"},
        }
    
    # Parse item: "instance:dbname"
    if ":" not in item:
        return {
            "changed": False,
            "msg": "invalid item format: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "expected 'instance:dbname'"},
        }
    
    instance_label, dbname = item.split(":", 1)
    
    instances = _mysql_instances(ctx)
    if len(instances) == 0:
        return {
            "changed": False,
            "msg": "MySQL not found on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no mysqld process found"},
        }
    
    # Find matching instance (use first/only instance)
    instance = instances[0]
    sizes = _query_db_sizes(ctx, instance)
    if sizes == None:
        return {
            "changed": False,
            "msg": "could not query MySQL database sizes",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "mysql query failed"},
        }
    
    if dbname not in sizes:
        return {
            "changed": False,
            "msg": "database %s not found" % dbname,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "database not found"},
        }
    
    size = sizes[dbname]
    levels = params.get("levels", None)
    
    # Apply levels (upper thresholds: warn at lower, crit at higher)
    state = "OK"
    if levels != None and levels != []:
        if len(levels) >= 1 and levels[0] != None:
            warn_level = levels[0]
            crit_level = levels[1] if len(levels) >= 2 and levels[1] != None else warn_level
            if size >= crit_level:
                state = "CRIT"
            elif size >= warn_level:
                state = "WARN"
    
    msg = "Size: %s" % _bytes_to_human(size)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"database_size": size},
            "details": "",
        },
    }