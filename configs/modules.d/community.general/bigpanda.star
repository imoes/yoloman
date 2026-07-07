def main(ctx, params):
    token = params["token"]
    state = params["state"]
    url = params.get("url", "https://api.bigpanda.io")
    component = params["component"]
    version = params["version"]
    source_system = params.get("source_system", "ansible")
    env = params.get("env")
    owner = params.get("owner")
    description = params.get("description")
    deployment_message = params.get("deployment_message")
    validate_certs = params.get("validate_certs", True)
    hosts_param = params.get("hosts")

    # Build the common request body
    body = {"component": component, "version": version}
    if hosts_param == None:
        body["hosts"] = [ctx.facts().get("hostname", "localhost")]
    else:
        if isinstance(hosts_param, list):
            body["hosts"] = hosts_param
        else:
            body["hosts"] = [hosts_param]

    # Insert state-specific attributes to body
    if state == "started":
        if source_system != None:
            body["source_system"] = source_system
        if env != None:
            body["env"] = env
        if owner != None:
            body["owner"] = owner
        if description != None:
            body["description"] = description
        request_url = url + "/data/events/deployments/start"
    else:
        if deployment_message != None:
            body["errorMessage"] = deployment_message
        if state == "finished":
            body["status"] = "success"
        else:
            body["status"] = "failure"
        request_url = url + "/data/events/deployments/end"

    # Build the deployment object we return
    deployment = {
        "token": token,
        "url": url,
        "component": component,
        "version": version,
        "hosts": body["hosts"],
    }
    if state == "started":
        if source_system != None:
            deployment["source_system"] = source_system
        if env != None:
            deployment["env"] = env
        if owner != None:
            deployment["owner"] = owner
        if description != None:
            deployment["description"] = description
    else:
        if deployment_message != None:
            deployment["message"] = deployment_message

    # Check mode: predict success without sending
    if ctx.check_mode:
        return {"changed": True, "msg": "would notify BigPanda", "data": deployment}

    # Prepare headers
    headers = {
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
    }

    # Send the data to BigPanda
    res = ctx.run(
        [
            "curl",
            "--silent",
            "--show-error",
            "--request",
            "POST",
            "--header",
            "Authorization: Bearer " + token,
            "--header",
            "Content-Type: application/json",
            "--data",
            str(body),
            request_url,
        ],
        mutates=True,
    )
    if res.skipped:
        return {"changed": True, "msg": "would notify BigPanda"}

    if res.rc != 0:
        fail("BigPanda API request failed: " + res.stderr)

    # Parse response (basic check for 200 status)
    if '"status": 200' in res.stdout or '"status":200' in res.stdout:
        return {"changed": True, "msg": "notify BigPanda succeeded", "data": deployment}
    else:
        fail("BigPanda API request failed with unexpected response: " + res.stdout)
