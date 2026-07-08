def main(ctx, params):
    service_path = params["service_path"]
    state = params.get("state", "present")
    region = params.get("region", "")
    stage = params.get("stage", "")
    deploy = params.get("deploy", True)
    force = params.get("force", False)
    verbose = params.get("verbose", False)
    serverless_bin_path = params.get("serverless_bin_path")

    # Validate service_path exists and contains serverless.yml
    sls_yml_path = service_path + "/serverless.yml"
    if not ctx.file_exists(sls_yml_path):
        fail("Could not find serverless.yml at " + sls_yml_path)

    # Read service name from serverless.yml
    content = ctx.file_read(sls_yml_path)

    # Simple key parser for 'service: name'
    service_name = None
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped.startswith("service:"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                service_name = parts[1].strip().strip('"').strip("'")
            break

    if service_name == None:
        fail("Could not read `service` key from serverless.yml file")

    # Compute service instance name
    if stage != "":
        service_instance = service_name + "-" + stage
    else:
        service_instance = service_name + "-" + "dev"

    # Build command
    if serverless_bin_path != None:
        bin_cmd = serverless_bin_path
    else:
        bin_cmd = "serverless"

    if state == "present":
        command = bin_cmd + " deploy"
    elif state == "absent":
        command = bin_cmd + " remove"
    else:
        fail("State must either be 'present' or 'absent'. Received: " + state)

    # Append flags for present state
    if state == "present":
        if not deploy:
            command += " --noDeploy"
        elif force:
            command += " --force"

    if region != "":
        command += " --region " + region
    if stage != "":
        command += " --stage " + stage
    if verbose:
        command += " --verbose"

    # Prepare argv list (split on spaces, preserve quoted strings if any)
    # Since serverless CLI args don't contain spaces in values, simple split is safe
    argv = command.split()
    res = ctx.run(argv, mutates=True, cwd=service_path)

    if res.skipped:
        # In check_mode, if we got here, state change is needed
        if state == "present":
            changed = True
        else:  # absent
            changed = True
        return {"changed": changed, "msg": "would execute " + command, "data": {
            "service_name": service_instance,
            "command": command
        }}

    if res.rc != 0:
        # Special handling for absent state when stack doesn't exist
        if state == "absent" and ("-{0}' does not exist".format(stage) in res.stdout or 
                                  "-{0}' does not exist".format(stage) in res.stderr):
            return {"changed": False, "msg": "Stack does not exist", "data": {
                "service_name": service_instance,
                "command": command,
                "state": "absent"
            }}

        fail("Failure when executing Serverless command. Exited {0}.\nstdout: {1}\nstderr: {2}".format(
            res.rc, res.stdout, res.stderr))

    # On success, mark changed based on state
    changed = True
    msg = "Service deployed successfully" if state == "present" else "Service removed successfully"
    return {"changed": changed, "msg": msg, "data": {
        "service_name": service_instance,
        "command": command,
        "state": state
    }}
