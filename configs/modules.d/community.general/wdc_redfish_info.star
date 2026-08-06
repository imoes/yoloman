def main(ctx, params):
    category = params["category"]
    command_list = params["command"]
    baseuri = params.get("baseuri")
    ioms = params.get("ioms")
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    timeout = str(params.get("timeout", 10))

    CATEGORY_COMMANDS_ALL = {
        "Update": ["SimpleUpdateStatus"]
    }

    # Validate category
    if category not in CATEGORY_COMMANDS_ALL:
        fail("Invalid Category '%s'. Valid Categories = %s" % (category, sorted(CATEGORY_COMMANDS_ALL.keys())))

    # Validate all commands
    for cmd in command_list:
        if cmd not in CATEGORY_COMMANDS_ALL[category]:
            fail("Invalid Command '%s'. Valid Commands = %s" % (cmd, CATEGORY_COMMANDS_ALL[category]))

    # Build root URIs
    if baseuri != None:
        root_uris = ["https://%s" % baseuri]
    else:
        if ioms == None or len(ioms) == 0:
            fail("Either baseuri or ioms must be provided")
        root_uris = ["https://" + iom for iom in ioms]

    # Prepare credentials string for redfish-cli (username:password or token)
    if auth_token != None:
        auth_str = "--auth-token %s" % auth_token
    elif username != None and password != None:
        auth_str = "--username %s --password '%s'" % (username, password)
    else:
        fail("Authentication requires either username+password or auth_token")

    # Execute redfish-cli commands
    result = {}
    for cmd in command_list:
        if category == "Update" and cmd == "SimpleUpdateStatus":
            # Build the redfish-cli command
            for uri in root_uris:
                cmd_args = [
                    "redfish-cli",
                    "-j",
                    "--timeout", timeout,
                    "-u", uri,
                    auth_str,
                    "-c", "GetSimpleUpdateStatus"
                ]
                res = ctx.run(cmd_args, mutates=False)
                if res.skipped:
                    # check_mode: skip is handled by runtime; return predicted change=False
                    continue
                if res.rc != 0:
                    fail("redfish-cli failed: " + res.stderr)
                # Parse JSON from stdout manually (no json module)
                # We expect JSON with keys like Description, ErrorCode, EstimatedRemainingMinutes, StatusCode
                # Use simple string parsing
                lines = res.stdout.strip().split("\n")
                for line in lines:
                    # Skip empty lines
                    if line.strip() == "":
                        continue
                    # Simple key: value parsing for expected fields
                    parts = line.split(":", 1)
                    if len(parts) == 2:
                        key = parts[0].strip()
                        value = parts[1].strip()
                        # Try to convert numeric values
                        if value.isdigit():
                            value = int(value)
                        elif value == "null":
                            value = None
                        # Initialize dict if needed
                        if "simple_update_status" not in result:
                            result["simple_update_status"] = {}
                        # Map key to lowercase for consistency with Ansible output
                        result["simple_update_status"][key.lower()] = value
                # Break after first successful IOM
                if "simple_update_status" in result:
                    break

    return {"changed": False, "redfish_facts": result}
