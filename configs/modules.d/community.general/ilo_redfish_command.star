def main(ctx, params):
    baseuri = params["baseuri"]
    category = params["category"]
    command_list = params["command"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    timeout = str(params.get("timeout", 60))

    # Validation: category must be 'Systems'
    if category != "Systems":
        fail("Invalid Category '" + category + "'. Valid Categories = ['Systems']")

    # Validation: commands must be supported for Systems category
    valid_commands = ["WaitforiLORebootCompletion"]
    for cmd in command_list:
        if cmd not in valid_commands:
            fail("Invalid Command '" + cmd + "'. Valid Commands = " + str(valid_commands))

    # Validation: authentication
    has_creds = (username != None and password != None)
    has_token = (auth_token != None)
    if not has_creds and not has_token:
        fail("Either username+password or auth_token must be provided")
    if has_creds and has_token:
        fail("username/password and auth_token are mutually exclusive")

    # Build base URL (always https)
    root_uri = "https://" + baseuri

    # Use curl to interact with Redfish API
    def redfish_request(method, path, headers=None, data=None):
        if headers == None:
            headers = []
        if data != None:
            headers.append("--data-binary")
            headers.append(data)
        headers.append("-s")
        headers.append("-k")  # skip SSL verification (common for iLO)
        headers.append("-w")
        headers.append("\\n%{http_code}")
        headers.append(root_uri + path)

        # Add auth header
        if auth_token != None:
            headers = ["-H", "X-Auth-Token: " + auth_token] + headers
        else:
            headers = ["-u", username + ":" + password] + headers

        if method == "POST":
            headers = ["-X", "POST"] + headers
        elif method == "PATCH":
            headers = ["-X", "PATCH"] + headers
        else:
            headers = ["-X", "GET"] + headers

        res = ctx.run(["curl"] + headers, mutates=(method != "GET"))
        if res.skipped:
            return {"rc": 0, "body": "", "code": "200", "changed": True}

        # Extract status code and body
        output = res.stdout
        lines = output.split("\n")
        if len(lines) < 2:
            return {"rc": res.rc, "body": output, "code": ""}
        code = lines[-1]
        body = "\n".join(lines[:-1])
        return {"rc": res.rc, "body": body, "code": code}

    # Wait for iLO reboot completion
    def wait_for_ilo_reboot_completion():
        # Poll for /redfish/v1/Managers/1/NetworkProtocol/HTTPS resource until ready
        # The endpoint becomes available after reboot
        attempts = 0
        max_attempts = int(timeout)
        delay_seconds = 1

        # Initial probe: try to fetch manager resource
        for i in range(max_attempts):
            res = redfish_request("GET", "/redfish/v1/Managers/1/NetworkProtocol/HTTPS")
            if res["code"] == "200":
                return {"ret": True, "changed": False, "msg": "iLO reboot completed successfully"}

            # Wait before next attempt
            ctx.run(["sleep", str(delay_seconds)])
            attempts += 1

        return {"ret": False, "changed": False, "msg": "Timeout waiting for iLO reboot completion"}

    # Execute commands
    result = {}
    command = command_list[0]
    if command == "WaitforiLORebootCompletion":
        result[command] = wait_for_ilo_reboot_completion()
    else:
        fail("Unsupported command: " + command)

    # Check result
    if not result[command]["ret"]:
        fail("Command '" + command + "' failed: " + result[command]["msg"])

    changed = result[command].get("changed", False)
    return {"changed": changed, "msg": "Command '" + command + "' completed successfully", "data": result}
