def main(ctx, params):
    parameter = params["parameter"]
    value = params.get("value")
    cluster = params.get("cluster", "localhost")
    port = params.get("port", "5433")
    login_user = params.get("login_user", "dbadmin")
    login_password = params.get("login_password")
    db = params.get("db", "")

    # Build DSN without exposing password in command line
    # We will use SQL commands directly via vsql for safety
    # First check vsql is available
    res = ctx.run(["which", "vsql"], mutates=False)
    if res.rc != 0:
        fail("vsql not found in PATH")

    # Build connection string components
    db_part = "-d " + db if db else ""
    user_part = "-U " + login_user
    pass_part = "PGPASSWORD=" + login_password if login_password else ""
    cluster_part = "-h " + cluster
    port_part = "-p " + port

    # Get current value via SELECT query
    query_cmd = "SELECT current_value FROM configuration_parameters WHERE parameter_name = '" + parameter + "' AND node_name = 'ALL'"
    cmd = ["bash", "-c", pass_part + " vsql " + cluster_part + " " + port_part + " " + db_part + " " + user_part + " -c '" + query_cmd + "' -t -A"]
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("Failed to query current parameter value: " + res.stderr)

    # Parse result - vsql returns single line without header (-t -A)
    current_value = res.stdout.strip() if res.stdout.strip() != "" else None

    # Check if change needed
    if value != None and value == current_value:
        return {"changed": False, "msg": parameter + " already set to " + str(value)}

    if ctx.check_mode:
        changed = value != current_value
        msg = "would set " + parameter + " to " + str(value) if changed else parameter + " already correct"
        return {"changed": changed, "msg": msg}

    # Apply change via ALTER DATABASE or SET CONFIG PARAMETER
    if value == None:
        # Reset to default - use RESET CONFIG PARAMETER
        set_cmd = "RESET CONFIG PARAMETER " + parameter
    else:
        set_cmd = "SET CONFIG PARAMETER " + parameter + " TO '" + value + "'"

    cmd = ["bash", "-c", pass_part + " vsql " + cluster_part + " " + port_part + " " + db_part + " " + user_part + " -c '" + set_cmd + "'"]
    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("Failed to set parameter " + parameter + ": " + res.stderr)

    return {"changed": True, "msg": parameter + " updated to " + str(value) if value != None else parameter + " reset to default"}
