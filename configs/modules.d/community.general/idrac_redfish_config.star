def main(ctx, params):
    baseuri = params["baseuri"]
    category = params["category"]
    command_list = params["command"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    manager_attributes = params.get("manager_attributes", {})
    timeout = params.get("timeout", 10)
    resource_id = params.get("resource_id")

    # Validate mutually exclusive auth options
    if username != None and auth_token != None:
        fail("cannot specify both username and auth_token")
    if username == None and auth_token == None:
        fail("one of username or auth_token is required")
    if username != None and password == None:
        fail("password is required when username is provided")

    # Validate category
    valid_categories = ["Manager"]
    if category not in valid_categories:
        fail("Invalid Category '%s'. Valid Categories = %s" % (category, valid_categories))

    # Validate commands per category
    valid_commands = {
        "Manager": ["SetManagerAttributes", "SetLifecycleControllerAttributes", "SetSystemAttributes"]
    }
    for cmd in command_list:
        if cmd not in valid_commands[category]:
            fail("Invalid Command '%s'. Valid Commands = %s" % (cmd, valid_commands[category]))

    # Check mutually exclusive commands
    if category == "Manager":
        exclusive_groups = [
            ["SetManagerAttributes", "SetLifecycleControllerAttributes", "SetSystemAttributes"]
        ]
        for group in exclusive_groups:
            found = [cmd for cmd in command_list if cmd in group]
            if len(found) > 1:
                fail("Commands %s are mutually exclusive" % found)

    # Build base URI
    root_uri = "https://" + baseuri

    # Prepare auth header
    headers = {"Content-Type": "application/json"}
    if auth_token != None:
        headers["X-Auth-Token"] = auth_token
    else:
        fail("Basic authentication with username/password is not supported in Starlark runtime")

    # Helper to perform HTTP GET/POST/PATCH
    def http_request(method, uri, data=None):
        url = root_uri + uri
        argv = ["curl", "-s", "-k", "-X", method, "-H", "Content-Type: application/json"]
        if auth_token != None:
            argv.extend(["-H", "X-Auth-Token: " + auth_token])
        if timeout != None:
            argv.extend(["--connect-timeout", str(timeout)])
        if data != None:
            argv.extend(["-d", data])
        argv.append(url)
        res = ctx.run(argv, mutates=(method != "GET"))
        if res.skipped:
            return {"ret": False, "msg": "would execute " + method + " " + url}
        if res.rc != 0:
            return {"ret": False, "msg": "HTTP " + method + " failed: " + res.stderr}
        # Simple JSON parsing by extracting first object between braces
        content = res.stdout.strip()
        if not content.startswith("{"):
            return {"ret": False, "msg": "non-JSON response: " + content[:200]}
        # Find first complete JSON object
        depth = 0
        start = content.find("{")
        if start == -1:
            return {"ret": False, "msg": "no JSON object found"}
        end = -1
        for i in range(start, len(content)):
            c = content[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        if end == -1:
            return {"ret": False, "msg": "unmatched braces in JSON"}
        json_str = content[start:end]
        fail("JSON parsing not supported in Starlark — cannot parse Redfish responses")

    # Main logic for Manager category
    if category == "Manager":
        # Build manager URI
        manager_uri = "/redfish/v1/Managers/" + (resource_id or "iDRAC.Embedded.1")

        # Map commands to URIs
        uri_map = {
            "SetManagerAttributes": manager_uri,
            "SetLifecycleControllerAttributes": "/redfish/v1/Managers/LifecycleController.Embedded.1",
            "SetSystemAttributes": "/redfish/v1/Managers/System.Embedded.1"
        }

        for command in command_list:
            uri = uri_map[command] + "/" + "Attributes"
            # GET /Attributes
            res = http_request("GET", uri)
            if not res.get("ret"):
                return {"changed": False, "msg": res["msg"], "failed": True}
            # JSON parsing not supported — fail with clear message
            fail("idrac_redfish_config cannot parse Redfish JSON responses in Starlark runtime")

        return {"changed": False, "msg": "no commands executed"}

    fail("Unsupported category: " + category)
