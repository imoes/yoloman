def main(ctx, params):
    backend = params["backend"]
    hostname = params["hostname"]
    name = params["name"]
    opendj_bindir = params.get("opendj_bindir", "/opt/opendj/bin")
    password = params.get("password")
    passwordfile = params.get("passwordfile")
    port = params["port"]
    state = params.get("state", "present")
    username = params.get("username", "cn=Directory Manager")
    value = params["value"]

    if state != "present":
        fail("only state=present is supported")

    # Validate authentication method
    if password != None and passwordfile != None:
        fail("password and passwordfile are mutually exclusive")
    if password == None and passwordfile == None:
        fail("one of password or passwordfile is required")

    # Build dsconfig base arguments
    def dsconfig_cmd(extra_args, mutates=False):
        argv = [
            opendj_bindir + "/dsconfig",
            "get-backend-prop" if not mutates else "set-backend-prop",
            "-h", hostname,
            "--port", port,
            "--bindDN", username,
            "--backend-name", backend,
            "-n", "-X"
        ] + (["-s"] if not mutates else []) + extra_args
        return argv

    # Build password argument list
    if password != None:
        password_arg = ["-w", password]
    else:
        password_arg = ["-j", passwordfile]

    # Read current property
    get_argv = dsconfig_cmd(password_arg, mutates=False)
    res = ctx.run(get_argv)
    if res.rc != 0:
        fail("failed to get backend properties: " + res.stderr)

    # Parse current value from output
    current_value = None
    for line in res.stdout.split("\n"):
        line = line.strip()
        if line.startswith(name + ":"):
            parts = line.split(":", 1)
            if len(parts) == 2:
                current_value = parts[1].strip()
            break

    # Compare and decide
    if current_value != None and current_value == value:
        return {"changed": False, "msg": name + " already has value " + value}

    # In check mode, report what would change
    if ctx.check_mode:
        return {"changed": True, "msg": "would update " + name + " to " + value}

    # Perform update
    set_argv = dsconfig_cmd(
        ["--set", name + ":" + value] + password_arg,
        mutates=True
    )
    res = ctx.run(set_argv)
    if res.rc != 0:
        fail("failed to update backend property: " + res.stderr)

    return {"changed": True, "msg": "updated " + name + " to " + value}
