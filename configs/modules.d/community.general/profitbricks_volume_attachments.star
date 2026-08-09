def main(ctx, params):
    datacenter = params.get("datacenter")
    server = params.get("server")
    volume = params.get("volume")
    subscription_user = params.get("subscription_user")
    subscription_password = params.get("subscription_password")
    wait = params.get("wait", True)
    wait_timeout = params.get("wait_timeout", 600)
    state = params.get("state", "present")

    # Required parameters check
    if subscription_user == None:
        fail("subscription_user parameter is required")
    if subscription_password == None:
        fail("subscription_password parameter is required")
    if datacenter == None:
        fail("datacenter parameter is required")
    if server == None:
        fail("server parameter is required")
    if volume == None:
        fail("volume parameter is required")

    # Validate wait_timeout is positive integer
    if type(wait_timeout) != "int" or wait_timeout < 0:
        fail("wait_timeout must be a non-negative integer")

    # Use PB environment variables if credentials not provided
    pb_user = subscription_user
    pb_password = subscription_password

    # Build CLI command based on state
    uuid_match = "^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"
    command = ["pb-cli", "volume-attachments", state]

    # Add required flags
    if not (datacenter.find("-") != -1 and len(datacenter) == 36):  # not UUID format
        command.append("--datacenter-name")
        command.append(datacenter)
    else:
        command.append("--datacenter-id")
        command.append(datacenter)

    if not (server.find("-") != -1 and len(server) == 36):
        command.append("--server-name")
        command.append(server)
    else:
        command.append("--server-id")
        command.append(server)

    if not (volume.find("-") != -1 and len(volume) == 36):
        command.append("--volume-name")
        command.append(volume)
    else:
        command.append("--volume-id")
        command.append(volume)

    # Authentication via env vars handled by pb-cli, no need to pass credentials here

    # Execute command
    res = ctx.run(command, mutates=True)

    # Handle skipped (check_mode)
    if res.skipped:
        return {"changed": True, "msg": "would " + state + " volume attachment"}

    # Check exit status
    if res.rc != 0:
        fail("failed to " + state + " volume attachment: " + res.stderr)

    # Wait for completion if requested
    if wait:
        # Polling for operation completion not directly supported via CLI
        # In practice, the CLI command returns when operation completes unless --async flag used
        # Assume the CLI handles waiting unless specified otherwise; timeout handling not implemented
        pass

    # Determine if changed based on operation type
    # Since we can't introspect state easily without SDK, assume change occurred unless already correct
    # Check current attachment status by listing
    list_command = ["pb-cli", "volumes", "list", "--server-name", server, "--datacenter-name", datacenter]
    list_res = ctx.run(list_command)
    if list_res.rc == 0:
        # Parse output (simple check for volume presence)
        # This is heuristic; in real scenarios, need robust parsing
        if state == "present" and volume in list_res.stdout:
            return {"changed": False, "msg": volume + " already attached"}
        if state == "absent" and volume not in list_res.stdout:
            return {"changed": False, "msg": volume + " already detached"}

    return {"changed": True, "msg": "volume " + state + " operation completed"}
