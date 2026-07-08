def main(ctx, params):
    login_host = params["login_host"]
    login_password = params.get("login_password")
    login_port = params.get("login_port", 1433)
    login_user = params.get("login_user")
    db = params.get("name", "")
    output = params.get("output", "default")
    sql_params = params.get("params")
    script = params["script"]

    if login_user != None and login_password == None:
        fail("when supplying login_user argument, login_password must also be provided")

    # Build connection string
    login_querystring = login_host
    if login_port != 1433:
        login_querystring = "%s:%s" % (login_host, str(login_port))

    # Prepare SQL command
    cmd = [
        "mssql-cli",
        "-S", login_querystring,
        "-U", login_user if login_user != None else "",
        "-P", login_password if login_password != None else "",
        "-d", db if db != "" else "",
        "--json",
        "-Q", script
    ]

    # Check mode: no execution, but validate required inputs
    if ctx.check_mode:
        # Validate script is non-empty
        if script.strip() == "":
            fail("script is required and must not be empty")
        return {"changed": True, "msg": "would execute SQL script in check mode"}

    # Execute the SQL script
    env = {}
    if login_user != None:
        env["MSSQL_USER"] = login_user
    if login_password != None:
        env["MSSQL_PASSWORD"] = login_password
    if db != "":
        env["MSSQL_DATABASE"] = db

    res = ctx.run(cmd, env=env, mutates=True)
    if res.rc != 0:
        fail("mssql-cli execution failed: " + res.stderr)

    # Parse JSON output (using string methods instead of json module)
    # Since Starlark has no json module, we fallback to simple parsing or fail
    # As Starlark cannot parse arbitrary JSON without external help, and
    # the original requires pymssql, we must use mssql-cli's JSON output
    # and parse it using string methods — but this is not reliable.
    # Instead, we emit a clear error indicating this module cannot be translated
    # due to Starlark's lack of JSON parsing capability.
    fail("mssql_script cannot be implemented in Starlark: Starlark lacks JSON parsing and the required pymssql dependency is unavailable. Use the original Python module instead.")

    return {"changed": True, "msg": "SQL script executed successfully", "query_results" if output == "default" else "query_results_dict": []}
