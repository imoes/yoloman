def main(ctx, params):
    database_name = params["database_name"]
    state = params.get("state", "present")

    hostname = params.get("hostname", "localhost")
    port = params.get("port", 8086)
    username = params.get("username", "root")
    password = params.get("password", "root")
    ssl = params.get("ssl", False)
    validate_certs = params.get("validate_certs", True)
    path = params.get("path", "")
    timeout = params.get("timeout")
    retries = params.get("retries", 3)
    use_udp = params.get("use_udp", False)
    udp_port = params.get("udp_port", 4444)

    # Build the InfluxDB URL
    scheme = "https" if ssl else "http"
    url_base = scheme + "://" + hostname
    if path != "" and len(path) > 0:
        url_base += "/" + path.lstrip("/")

    # Get list of databases (read-only probe)
    cmd = [
        "curl", "-s", "-X", "GET",
        url_base + "/query",
        "-G",
        "--data-urlencode", "q=SHOW DATABASES",
        "-d", "u=" + username,
        "-d", "p=" + password,
    ]
    if validate_certs == False:
        cmd.append("-k")
    if timeout != None:
        cmd.extend(["--max-time", str(timeout)])

    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("failed to list databases: " + res.stderr)

    # Parse JSON using simple string search
    db_list = []
    # Look for pattern "values":[["name"],...] or ["name"]
    stdout = res.stdout
    if '"results"' in stdout and '"series"' in stdout:
        # Extract values array content
        values_start = stdout.find('"values"')
        if values_start != -1:
            bracket_start = stdout.find('[', values_start)
            if bracket_start != -1:
                # Parse the list manually
                content = stdout[bracket_start:]
                # Very simple parsing for known format
                idx = 0
                while idx < len(content):
                    if content[idx] == '"':
                        # Found a quoted string
                        end = idx + 1
                        while end < len(content) and content[end] != '"':
                            if content[end] == '\\':
                                end = end + 2
                            else:
                                end = end + 1
                        if end < len(content):
                            db_name = content[idx+1:end]
                            if db_name != "":
                                db_list.append(db_name)
                        idx = end + 1
                    else:
                        idx = idx + 1

    present = database_name in db_list

    if state == "present":
        if present:
            return {"changed": False, "msg": "database " + database_name + " already exists"}
        # Create database via HTTP POST
        create_cmd = [
            "curl", "-s", "-X", "POST",
            url_base + "/query",
            "-G",
            "--data-urlencode", "q=CREATE DATABASE " + database_name,
            "-d", "u=" + username,
            "-d", "p=" + password,
        ]
        if validate_certs == False:
            create_cmd.append("-k")
        if timeout != None:
            create_cmd.extend(["--max-time", str(timeout)])

        create_res = ctx.run(create_cmd, mutates=True)
        if create_res.skipped:
            return {"changed": True, "msg": "would create database " + database_name}
        if create_res.rc != 0:
            fail("failed to create database " + database_name + ": " + create_res.stderr)
        # Verify creation by re-fetching DB list
        verify_cmd = [
            "curl", "-s", "-X", "GET",
            url_base + "/query",
            "-G",
            "--data-urlencode", "q=SHOW DATABASES",
            "-d", "u=" + username,
            "-d", "p=" + password,
        ]
        if validate_certs == False:
            verify_cmd.append("-k")
        if timeout != None:
            verify_cmd.extend(["--max-time", str(timeout)])

        verify_res = ctx.run(verify_cmd, mutates=False)
        if verify_res.rc != 0:
            fail("failed to verify database creation: " + verify_res.stderr)
        # Re-parse the list
        new_db_list = []
        vout = verify_res.stdout
        if '"results"' in vout and '"series"' in vout:
            values_start = vout.find('"values"')
            if values_start != -1:
                bracket_start = vout.find('[', values_start)
                if bracket_start != -1:
                    content = vout[bracket_start:]
                    idx = 0
                    while idx < len(content):
                        if content[idx] == '"':
                            end = idx + 1
                            while end < len(content) and content[end] != '"':
                                if content[end] == '\\':
                                    end = end + 2
                                else:
                                    end = end + 1
                            if end < len(content):
                                db_name = content[idx+1:end]
                                if db_name != "":
                                    new_db_list.append(db_name)
                            idx = end + 1
                        else:
                            idx = idx + 1

        if database_name not in new_db_list:
            fail("database " + database_name + " not found after creation")
        return {"changed": True, "msg": "database " + database_name + " created"}

    if state == "absent":
        if not present:
            return {"changed": False, "msg": "database " + database_name + " does not exist"}
        # Drop database via HTTP POST
        drop_cmd = [
            "curl", "-s", "-X", "POST",
            url_base + "/query",
            "-G",
            "--data-urlencode", "q=DROP DATABASE " + database_name,
            "-d", "u=" + username,
            "-d", "p=" + password,
        ]
        if validate_certs == False:
            drop_cmd.append("-k")
        if timeout != None:
            drop_cmd.extend(["--max-time", str(timeout)])

        drop_res = ctx.run(drop_cmd, mutates=True)
        if drop_res.skipped:
            return {"changed": True, "msg": "would drop database " + database_name}
        if drop_res.rc != 0:
            fail("failed to drop database " + database_name + ": " + drop_res.stderr)
        # Verify deletion
        verify_cmd = [
            "curl", "-s", "-X", "GET",
            url_base + "/query",
            "-G",
            "--data-urlencode", "q=SHOW DATABASES",
            "-d", "u=" + username,
            "-d", "p=" + password,
        ]
        if validate_certs == False:
            verify_cmd.append("-k")
        if timeout != None:
            verify_cmd.extend(["--max-time", str(timeout)])

        verify_res = ctx.run(verify_cmd, mutates=False)
        if verify_res.rc != 0:
            fail("failed to verify database deletion: " + verify_res.stderr)
        # Re-parse the list
        final_db_list = []
        vout = verify_res.stdout
        if '"results"' in vout and '"series"' in vout:
            values_start = vout.find('"values"')
            if values_start != -1:
                bracket_start = vout.find('[', values_start)
                if bracket_start != -1:
                    content = vout[bracket_start:]
                    idx = 0
                    while idx < len(content):
                        if content[idx] == '"':
                            end = idx + 1
                            while end < len(content) and content[end] != '"':
                                if content[end] == '\\':
                                    end = end + 2
                                else:
                                    end = end + 1
                            if end < len(content):
                                db_name = content[idx+1:end]
                                if db_name != "":
                                    final_db_list.append(db_name)
                            idx = end + 1
                        else:
                            idx = idx + 1

        if database_name in final_db_list:
            fail("database " + database_name + " still exists after deletion")
        return {"changed": True, "msg": "database " + database_name + " dropped"}

    fail("unsupported state: " + state)
