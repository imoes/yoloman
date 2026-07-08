def main(ctx, params):
    cluster = params.get("cluster", "localhost")
    port = params.get("port", "5433")
    db = params.get("db")
    login_user = params.get("login_user", "dbadmin")
    login_password = params.get("login_password")

    if db == None:
        fail("db is required to gather vertica facts")
    if login_password == None:
        fail("login_password is required to authenticate")

    dsn = (
        "Driver=Vertica;" +
        "Server=%s;" +
        "Port=%s;" +
        "Database=%s;" +
        "User=%s;" +
        "Password=%s;" +
        "ConnectionLoadBalance=%s"
    ) % (cluster, port, db, login_user, login_password, "true")

    cmd_prefix = ["psql", "-h", cluster, "-p", port, "-U", login_user, "-d", db, "-t", "-A", "-F", "\t"]

    def run_query(sql):
        res = ctx.run(cmd_prefix + ["-c", sql])
        if res.rc != 0:
            fail("psql query failed: " + res.stderr)
        return res.stdout

    def get_schemas():
        sql = """
            SELECT schema_name, schema_owner, create_time
            FROM schemata
            WHERE NOT is_system_schema AND schema_name NOT IN ('public')
            ORDER BY schema_name
        """
        lines = run_query(sql).split("\n")
        facts = {}
        for i in range(len(lines)):
            line = lines[i]
            if line.strip() == "":
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            name = parts[0]
            owner = parts[1]
            create_time = parts[2]
            facts[name.lower()] = {
                "name": name,
                "owner": owner,
                "create_time": str(create_time),
                "usage_roles": [],
                "create_roles": []
            }
        return facts

    def get_users():
        sql = """
            SELECT u.user_name, u.is_locked, u.lock_time,
                   p.password, p.acctexpired,
                   u.profile_name, u.resource_pool,
                   u.all_roles, u.default_roles
            FROM users u
            JOIN password_auditor p ON p.user_id = u.user_id
            WHERE NOT u.is_super_user
            ORDER BY u.user_name
        """
        lines = run_query(sql).split("\n")
        facts = {}
        for i in range(len(lines)):
            line = lines[i]
            if line.strip() == "":
                continue
            parts = line.split("\t")
            if len(parts) < 9:
                continue
            user_name = parts[0]
            is_locked = parts[1]
            lock_time = parts[2] if parts[2] != "" else None
            password = parts[3]
            acctexpired = parts[4]
            profile = parts[5]
            resource_pool = parts[6]
            all_roles = parts[7]
            default_roles = parts[8]

            user_key = user_name.lower()
            user_obj = {
                "name": user_name,
                "locked": str(is_locked),
                "password": password,
                "expired": str(acctexpired),
                "profile": profile,
                "resource_pool": resource_pool,
                "roles": [],
                "default_roles": []
            }
            if lock_time != None:
                user_obj["locked_time"] = str(lock_time)
            if all_roles != "":
                user_obj["roles"] = [r.strip() for r in all_roles.split(",") if r.strip()]
            if default_roles != "":
                user_obj["default_roles"] = [r.strip() for r in default_roles.split(",") if r.strip()]
            facts[user_key] = user_obj
        return facts

    def get_roles():
        sql = """
            SELECT r.name, r.assigned_roles
            FROM roles r
            ORDER BY r.name
        """
        lines = run_query(sql).split("\n")
        facts = {}
        for i in range(len(lines)):
            line = lines[i]
            if line.strip() == "":
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            name = parts[0]
            assigned = parts[1]
            role_obj = {
                "name": name,
                "assigned_roles": [r.strip() for r in assigned.split(",") if r.strip()] if assigned != "" else []
            }
            facts[name.lower()] = role_obj
        return facts

    def get_config():
        sql = """
            SELECT c.parameter_name, c.current_value, c.default_value
            FROM configuration_parameters c
            WHERE c.node_name = 'ALL'
            ORDER BY c.parameter_name
        """
        lines = run_query(sql).split("\n")
        facts = {}
        for i in range(len(lines)):
            line = lines[i]
            if line.strip() == "":
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            name = parts[0]
            facts[name.lower()] = {
                "parameter_name": name,
                "current_value": parts[1],
                "default_value": parts[2]
            }
        return facts

    def get_nodes():
        sql = """
            SELECT node_name, node_address, export_address, node_state, node_type, catalog_path
            FROM nodes
            ORDER BY node_address
        """
        lines = run_query(sql).split("\n")
        facts = {}
        for i in range(len(lines)):
            line = lines[i]
            if line.strip() == "":
                continue
            parts = line.split("\t")
            if len(parts) < 6:
                continue
            addr = parts[1]
            facts[addr] = {
                "node_name": parts[0],
                "export_address": parts[2],
                "node_state": parts[3],
                "node_type": parts[4],
                "catalog_path": parts[5]
            }
        return facts

    schema_facts = get_schemas()
    user_facts = get_users()
    role_facts = get_roles()
    configuration_facts = get_config()
    node_facts = get_nodes()

    return {
        "changed": False,
        "msg": "Gathered Vertica facts",
        "data": {
            "vertica_schemas": schema_facts,
            "vertica_users": user_facts,
            "vertica_roles": role_facts,
            "vertica_configuration": configuration_facts,
            "vertica_nodes": node_facts
        }
    }
