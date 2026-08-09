def main(ctx, params):
    role = params["role"]
    state = params.get("state", "present")
    assigned_roles_str = params.get("assigned_roles")
    cluster = params.get("cluster", "localhost")
    port = params.get("port", "5433")
    login_user = params.get("login_user", "dbadmin")
    login_password = params.get("login_password")
    db = params.get("db", "")

    if state == "absent":
        fail("state 'absent' is not supported in this translation")
    if state == "locked":
        fail("state 'locked' is not supported in this translation")

    # Build ODBC DSN
    dsn = "Driver=Vertica;" + "Server=" + cluster + ";" + "Port=" + str(port) + ";" + "Database=" + db + ";" + "User=" + login_user + ";" + "Password=" + (login_password if login_password != None else "") + ";" + "ConnectionLoadBalance=true"

    # Execute vsql command via ctx.run to avoid pyodbc dependency
    # Check if role exists
    check_cmd = ["vsql", "-h", cluster, "-p", str(port), "-U", login_user, "-d", db, "-c", "SELECT 1 FROM roles WHERE name = \'" + role + "\'"]
    if login_password != None:
        check_cmd = check_cmd + ["-w", login_password]

    res = ctx.run(check_cmd)
    if res.rc != 0:
        fail("Unable to check role existence: " + res.stderr)

    role_exists = "1" in res.stdout

    # Parse assigned_roles
    assigned_roles = []
    if assigned_roles_str != None and len(assigned_roles_str) > 0:
        assigned_roles = assigned_roles_str.split(",")

    if ctx.check_mode:
        if not role_exists:
            changed = True
        elif len(assigned_roles) > 0:
            # Check assigned roles via vsql
            check_grants_cmd = ["vsql", "-h", cluster, "-p", str(port), "-U", login_user, "-d", db, "-c", "SELECT assigned_roles FROM roles WHERE name = \'" + role + "\'"]
            if login_password != None:
                check_grants_cmd = check_grants_cmd + ["-w", login_password]

            grants_res = ctx.run(check_grants_cmd)
            if grants_res.rc != 0:
                fail("Unable to check assigned roles: " + grants_res.stderr)

            # Parse current assigned roles
            current_roles = []
            if len(grants_res.stdout.strip()) > 0:
                # Output format is like "role1, role2" or empty
                raw = grants_res.stdout.strip()
                if "\n" in raw:
                    raw = raw.split("\n")[-1]
                raw = raw.strip()
                if len(raw) > 0:
                    current_roles = [r.strip() for r in raw.split(",") if len(r.strip()) > 0]

            # Normalize lists for comparison
            expected_roles = sorted([r.strip() for r in assigned_roles if len(r.strip()) > 0])
            actual_roles = sorted(current_roles)

            if expected_roles != actual_roles:
                changed = True
            else:
                changed = False
        else:
            changed = False
        return {"changed": changed, "msg": "would create role " + role if not role_exists else "role already exists and matches"}

    # Create role if missing
    if not role_exists:
        create_cmd = ["vsql", "-h", cluster, "-p", str(port), "-U", login_user, "-d", db, "-c", "CREATE ROLE " + role]
        if login_password != None:
            create_cmd = create_cmd + ["-w", login_password]

        res = ctx.run(create_cmd)
        if res.rc != 0:
            fail("Failed to create role " + role + ": " + res.stderr)

        role_exists = True

    # Handle assigned roles
    if len(assigned_roles) > 0:
        # Get current assigned roles
        check_grants_cmd = ["vsql", "-h", cluster, "-p", str(port), "-U", login_user, "-d", db, "-c", "SELECT assigned_roles FROM roles WHERE name = \'" + role + "\'"]
        if login_password != None:
            check_grants_cmd = check_grants_cmd + ["-w", login_password]

        grants_res = ctx.run(check_grants_cmd)
        if grants_res.rc != 0:
            fail("Unable to check assigned roles: " + grants_res.stderr)

        current_roles = []
        if len(grants_res.stdout.strip()) > 0:
            raw = grants_res.stdout.strip()
            if "\n" in raw:
                raw = raw.split("\n")[-1]
            raw = raw.strip()
            if len(raw) > 0:
                current_roles = [r.strip() for r in raw.split(",") if len(r.strip()) > 0]

        expected_roles = [r.strip() for r in assigned_roles if len(r.strip()) > 0]

        to_revoke = []
        to_grant = []
        for r in current_roles:
            if not r in expected_roles:
                to_revoke.append(r)
        for r in expected_roles:
            if not r in current_roles:
                to_grant.append(r)

        changed = len(to_revoke) > 0 or len(to_grant) > 0

        for r in to_revoke:
            revoke_cmd = ["vsql", "-h", cluster, "-p", str(port), "-U", login_user, "-d", db, "-c", "REVOKE " + r + " FROM " + role]
            if login_password != None:
                revoke_cmd = revoke_cmd + ["-w", login_password]
            res = ctx.run(revoke_cmd)
            if res.rc != 0:
                fail("Failed to revoke role " + r + " from " + role + ": " + res.stderr)

        for r in to_grant:
            grant_cmd = ["vsql", "-h", cluster, "-p", str(port), "-U", login_user, "-d", db, "-c", "GRANT " + r + " TO " + role]
            if login_password != None:
                grant_cmd = grant_cmd + ["-w", login_password]
            res = ctx.run(grant_cmd)
            if res.rc != 0:
                fail("Failed to grant role " + r + " to " + role + ": " + res.stderr)
    else:
        # If no assigned_roles specified, ensure no roles are assigned
        check_grants_cmd = ["vsql", "-h", cluster, "-p", str(port), "-U", login_user, "-d", db, "-c", "SELECT assigned_roles FROM roles WHERE name = \'" + role + "\'"]
        if login_password != None:
            check_grants_cmd = check_grants_cmd + ["-w", login_password]

        grants_res = ctx.run(check_grants_cmd)
        if grants_res.rc != 0:
            fail("Unable to check assigned roles: " + grants_res.stderr)

        current_roles = []
        if len(grants_res.stdout.strip()) > 0:
            raw = grants_res.stdout.strip()
            if "\n" in raw:
                raw = raw.split("\n")[-1]
            raw = raw.strip()
            if len(raw) > 0:
                current_roles = [r.strip() for r in raw.split(",") if len(r.strip()) > 0]

        changed = len(current_roles) > 0

        if changed:
            for r in current_roles:
                revoke_cmd = ["vsql", "-h", cluster, "-p", str(port), "-U", login_user, "-d", db, "-c", "REVOKE " + r + " FROM " + role]
                if login_password != None:
                    revoke_cmd = revoke_cmd + ["-w", login_password]
                res = ctx.run(revoke_cmd)
                if res.rc != 0:
                    fail("Failed to revoke role " + r + " from " + role + ": " + res.stderr)

    msg = "role " + role + " created" if not role_exists else "role " + role + " updated"
    return {"changed": changed, "msg": msg}
