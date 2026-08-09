def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    description = params.get("description")
    location = params.get("location")
    parent_name = params.get("parent")
    wait = params.get("wait", True)

    # Check required environment variables are set
    env = ctx.facts().get("env", {})
    v2_api_token = env.get("CLC_V2_API_TOKEN", "")
    clc_alias = env.get("CLC_ACCT_ALIAS", "")
    v2_api_username = env.get("CLC_V2_API_USERNAME", "")
    v2_api_passwd = env.get("CLC_V2_API_PASSWD", "")
    api_url = env.get("CLC_V2_API_URL", "")

    # Validate required credentials
    if not v2_api_token and not v2_api_username:
        fail("You must set the CLC_V2_API_USERNAME and CLC_V2_API_PASSWD " +
             "environment variables, or CLC_V2_API_TOKEN and CLC_ACCT_ALIAS")
    
    # Build the CLC CLI command
    cmd = ["clc", "group"]

    if api_url:
        cmd.extend(["--api-url", api_url])

    if v2_api_token and clc_alias:
        cmd.extend(["--token", v2_api_token, "--alias", clc_alias])
    elif v2_api_username and v2_api_passwd:
        cmd.extend(["--username", v2_api_username, "--password", v2_api_passwd])
    else:
        fail("Invalid credential configuration")

    # Build group operation command
    cmd.append(state)

    if location:
        cmd.extend(["--location", location])
    
    if parent_name:
        cmd.extend(["--parent", parent_name])
    
    if description:
        cmd.extend(["--description", description])
    
    cmd.append(name)

    # Probe current state
    probe_cmd = cmd[:-1] + ["show", name]
    if location:
        # Remove location if already in probe_cmd, as it's not supported for show
        probe_cmd = ["clc", "group", "show", name]
        if v2_api_token and clc_alias:
            probe_cmd = probe_cmd[:2] + ["--token", v2_api_token, "--alias", clc_alias] + probe_cmd[2:]
        elif v2_api_username and v2_api_passwd:
            probe_cmd = probe_cmd[:2] + ["--username", v2_api_username, "--password", v2_api_passwd] + probe_cmd[2:]
    
    res = ctx.run(probe_cmd)
    exists = res.rc == 0

    if state == "absent":
        if not exists:
            return {"changed": False, "msg": "group " + name + " does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete group " + name}
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("failed to delete group " + name + ": " + res.stderr)
        return {"changed": True, "msg": "deleted group " + name}
    
    # state == "present"
    if exists:
        # Check for description or location mismatches (basic check)
        if description or location or parent_name:
            # For full idempotency we'd need to compare attributes, but
            # this is a minimal implementation for core functionality.
            pass  # Consider it present if exists and name matches
        return {"changed": False, "msg": "group " + name + " already exists"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would create group " + name}
    
    res = ctx.run(cmd, mutates=True)
    if res.rc != 0:
        fail("failed to create group " + name + ": " + res.stderr)
    
    return {"changed": True, "msg": "created group " + name}
