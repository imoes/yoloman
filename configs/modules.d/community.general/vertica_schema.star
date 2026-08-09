def main(ctx, params):
    schema = params["schema"]
    usage_roles = []
    if params.get("usage_roles"):
        usage_roles = [r.strip() for r in params["usage_roles"].split(",") if r.strip()]
    create_roles = []
    if params.get("create_roles"):
        create_roles = [r.strip() for r in params["create_roles"].split(",") if r.strip()]
    owner = params.get("owner")
    state = params.get("state", "present")
    db = params.get("db", "")
    cluster = params.get("cluster", "localhost")
    port = params.get("port", "5433")
    login_user = params.get("login_user", "dbadmin")
    login_password = params.get("login_password", "")

    if state != "present" and state != "absent":
        fail("unsupported state: " + state)

    if state == "absent":
        # Check if schema exists
        query = "SELECT schema_name FROM v_catalog.schemata WHERE schema_name = '" + schema + "' AND NOT is_system_schema AND schema_name NOT IN ('public','TxtIndex')"
        res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", query])
        if res.rc != 0:
            fail("failed to query schema: " + res.stderr)
        schema_exists = res.stdout.strip() != ""

        if not schema_exists:
            return {"changed": False, "msg": "schema " + schema + " does not exist"}

        # Get roles for the schema
        role_query = "SELECT r.name FROM v_catalog.grants g JOIN v_catalog.roles r ON r.role_id = g.grantee_id WHERE g.object_name = '" + schema + "' AND g.object_type = 'SCHEMA' AND g.grantee NOT IN ('public','dbadmin')"
        res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", role_query])
        if res.rc != 0:
            fail("failed to query roles: " + res.stderr)

        roles = []
        if res.stdout.strip():
            roles = res.stdout.strip().split("\n")

        # Drop roles first
        for role in roles:
            if role:
                res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", "DROP ROLE " + role + " CASCADE;"])
                if res.rc != 0:
                    fail("failed to drop role " + role + ": " + res.stderr)

        # Drop schema
        res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", "DROP SCHEMA " + schema + " RESTRICT;"])
        if res.rc != 0:
            fail("failed to drop schema " + schema + ": " + res.stderr)

        return {"changed": True, "msg": "dropped schema " + schema}

    # state == "present"
    query = "SELECT schema_name, schema_owner FROM v_catalog.schemata WHERE schema_name = '" + schema + "' AND NOT is_system_schema AND schema_name NOT IN ('public','TxtIndex')"
    res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", query])
    if res.rc != 0:
        fail("failed to query schema: " + res.stderr)

    schema_exists = res.stdout.strip() != ""
    current_owner = ""
    if schema_exists:
        parts = res.stdout.strip().split("|")
        if len(parts) >= 2:
            current_owner = parts[1]

    if not schema_exists:
        # Create schema
        create_query = "CREATE SCHEMA " + schema
        if owner:
            create_query += " AUTHORIZATION " + owner
        res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", create_query + ";"])
        if res.rc != 0:
            fail("failed to create schema " + schema + ": " + res.stderr)

        # Create roles and grant privileges
        for role in usage_roles + create_roles:
            if role:
                res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", "CREATE ROLE " + role + ";"])
                if res.rc != 0 and "already exists" not in res.stderr:
                    fail("failed to create role " + role + ": " + res.stderr)
                res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", "GRANT USAGE ON SCHEMA " + schema + " TO " + role + ";"])
                if res.rc != 0:
                    fail("failed to grant usage on schema for role " + role + ": " + res.stderr)

        for role in create_roles:
            if role:
                res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", "GRANT CREATE ON SCHEMA " + schema + " TO " + role + ";"])
                if res.rc != 0:
                    fail("failed to grant create on schema for role " + role + ": " + res.stderr)

        return {"changed": True, "msg": "created schema " + schema}

    # Schema exists
    changed = False

    if owner and owner != current_owner:
        fail("changing schema owner is not supported. current owner: " + current_owner)

    # Get current roles for the schema
    role_query = "SELECT r.name, CASE WHEN g.privileges_description LIKE '%CREATE%' THEN 'create' ELSE 'usage' END as priv FROM v_catalog.grants g JOIN v_catalog.roles r ON r.role_id = g.grantee_id WHERE g.object_name = '" + schema + "' AND g.object_type = 'SCHEMA' AND g.grantee NOT IN ('public','dbadmin')"
    res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", role_query])
    if res.rc != 0:
        fail("failed to query roles: " + res.stderr)

    current_usage = []
    current_create = []
    if res.stdout.strip():
        for line in res.stdout.strip().split("\n"):
            if line:
                parts = line.split("|")
                if len(parts) >= 2:
                    if parts[1] == "create":
                        current_create.append(parts[0])
                    else:
                        current_usage.append(parts[0])

    # Compare and sync roles
    usage_to_add = [r for r in usage_roles if r not in current_usage and r not in create_roles]
    create_to_add = [r for r in create_roles if r not in current_create]
    all_current = current_usage + current_create
    roles_to_drop = [r for r in all_current if r not in usage_roles and r not in create_roles]

    for role in roles_to_drop:
        res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", "DROP ROLE " + role + " CASCADE;"])
        if res.rc != 0:
            fail("failed to drop role " + role + ": " + res.stderr)

    for role in current_create:
        if role and role not in create_roles:
            res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", "REVOKE CREATE ON SCHEMA " + schema + " FROM " + role + ";"])
            if res.rc != 0:
                fail("failed to revoke create on schema for role " + role + ": " + res.stderr)

    for role in usage_to_add + create_to_add:
        res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", "CREATE ROLE " + role + ";"])
        if res.rc != 0 and "already exists" not in res.stderr:
            fail("failed to create role " + role + ": " + res.stderr)
        res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", "GRANT USAGE ON SCHEMA " + schema + " TO " + role + ";"])
        if res.rc != 0:
            fail("failed to grant usage on schema for role " + role + ": " + res.stderr)

    for role in create_to_add:
        res = ctx.run(["psql", "-d", db, "-h", cluster, "-p", port, "-U", login_user, "-t", "-A", "-c", "GRANT CREATE ON SCHEMA " + schema + " TO " + role + ";"])
        if res.rc != 0:
            fail("failed to grant create on schema for role " + role + ": " + res.stderr)

    if len(usage_to_add) > 0 or len(create_to_add) > 0 or len(roles_to_drop) > 0:
        changed = True

    if changed:
        return {"changed": True, "msg": "updated schema " + schema}
    return {"changed": False, "msg": "schema " + schema + " already exists"}
