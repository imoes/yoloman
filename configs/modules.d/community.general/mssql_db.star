def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    autocommit = params.get("autocommit", False)
    target = params.get("target")
    login_user = params.get("login_user", "")
    login_password = params.get("login_password", "")
    login_host = params["login_host"]
    login_port = params.get("login_port", "1433")

    # Validate required combinations
    if login_user != "" and login_password == "":
        fail("when supplying login_user arguments login_password must be provided")

    # Build connection string
    conn_str = login_host
    if login_port != "1433":
        conn_str = "%s:%s" % (login_host, login_port)

    # Check database existence (read-only probe)
    cmd = [
        "sqlcmd",
        "-S", conn_str,
        "-U", login_user,
        "-P", login_password,
        "-d", "master",
        "-Q", "SELECT name FROM master.sys.databases WHERE name = '" + name + "'"
    ]
    res = ctx.run(cmd, mutates=False)
    db_exists = res.rc == 0 and name in res.stdout

    # Handle state transitions
    if state == "absent":
        if not db_exists:
            return {"changed": False, "msg": "database %s does not exist" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would drop database %s" % name}

        # Drop database with single_user mode
        cmds = [
            ["sqlcmd", "-S", conn_str, "-U", login_user, "-P", login_password, "-d", "master",
             "-Q", "ALTER DATABASE [" + name + "] SET single_user WITH ROLLBACK IMMEDIATE"],
            ["sqlcmd", "-S", conn_str, "-U", login_user, "-P", login_password, "-d", "master",
             "-Q", "DROP DATABASE [" + name + "]"]
        ]
        for cmd in cmds:
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0 and "Database does not exist" not in res.stderr:
                fail("failed to drop database: " + res.stderr)

        return {"changed": True, "msg": "database %s dropped" % name}

    elif state == "present":
        if db_exists:
            return {"changed": False, "msg": "database %s already exists" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would create database %s" % name}

        res = ctx.run([
            "sqlcmd",
            "-S", conn_str,
            "-U", login_user,
            "-P", login_password,
            "-d", "master",
            "-Q", "CREATE DATABASE [" + name + "]"
        ], mutates=True)
        if res.rc != 0:
            fail("failed to create database: " + res.stderr)
        return {"changed": True, "msg": "database %s created" % name}

    elif state == "import":
        if not target:
            fail("target is required when state is import")
        if not ctx.file_exists(target):
            fail("cannot find target file: " + target)

        if not db_exists:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create database %s and import from %s" % (name, target)}
            
            # Create database first
            res = ctx.run([
                "sqlcmd",
                "-S", conn_str,
                "-U", login_user,
                "-P", login_password,
                "-d", "master",
                "-Q", "CREATE DATABASE [" + name + "]"
            ], mutates=True)
            if res.rc != 0:
                fail("failed to create database: " + res.stderr)
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would import into existing database %s from %s" % (name, target)}

        # Read target file and execute SQL commands
        sql_content = ctx.file_read(target)
        sql_lines = sql_content.split("\n")
        
        # Build batches for sqlcmd - separate by GO statements
        batch = ""
        for line in sql_lines:
            stripped = line.strip().upper()
            if stripped == "GO":
                if batch:
                    res = ctx.run([
                        "sqlcmd",
                        "-S", conn_str,
                        "-U", login_user,
                        "-P", login_password,
                        "-d", name,
                        "-Q", batch
                    ], mutates=True)
                    if res.rc != 0:
                        fail("failed to execute SQL batch: " + res.stderr)
                batch = ""
            else:
                batch += line + "\n"
        
        # Execute remaining batch
        if batch:
            res = ctx.run([
                "sqlcmd",
                "-S", conn_str,
                "-U", login_user,
                "-P", login_password,
                "-d", name,
                "-Q", batch
            ], mutates=True)
            if res.rc != 0:
                fail("failed to execute SQL batch: " + res.stderr)

        return {"changed": True, "msg": "database %s imported from %s" % (name, target)}

    else:
        fail("unsupported state: " + state)
