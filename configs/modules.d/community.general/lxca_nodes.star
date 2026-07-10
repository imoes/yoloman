def main(ctx, params):
    auth_url = params["auth_url"]
    login_user = params["login_user"]
    login_password = params["login_password"]
    command = params.get("command_options", "nodes")
    uuid = params.get("uuid")
    chassis = params.get("chassis")

    # Validate required parameters for specific commands
    if command == "nodes_by_uuid" and uuid == None:
        fail("UUID of device is required for nodes_by_uuid command.")
    if command == "nodes_by_chassis_uuid" and chassis == None:
        fail("UUID of chassis is required for nodes_by_chassis_uuid command.")

    # Map command to endpoint path
    # All endpoints return JSON data, so we use the same curl command and adjust path
    path_map = {
        "nodes": "/v1/Nodes",
        "nodes_by_uuid": "/v1/Nodes/" + uuid,
        "nodes_by_chassis_uuid": "/v1/Nodes?chassisUUID=" + chassis,
        "nodes_status_managed": "/v1/Nodes?status=managed",
        "nodes_status_unmanaged": "/v1/Nodes?status=unmanaged"
    }

    path = path_map.get(command)
    if path == None:
        fail("unsupported command_options: " + command)

    # Build curl command: no shell, use list argv
    # -s: silent, -k: allow insecure (since lxca often uses self-signed cert)
    # -u: user:password, -H: JSON accept
    # We use -o /dev/null to discard body, then read separately for check_mode efficiency
    # But to return data, we need to capture stdout — use -o - (stdout)
    curl_argv = [
        "curl", "-s", "-k", "-u", login_user + ":" + login_password,
        "-H", "Accept: application/json",
        auth_url + path
    ]

    # In check_mode, we still need to run read-only probe to validate connectivity and data
    # But this module returns data — so we always run it; check_mode support is "none" per original docs.
    # Since original docs say check_mode support: none, we act the same — always run and mutate nothing.
    res = ctx.run(curl_argv, mutates=False)
    if res.rc != 0:
        fail("failed to fetch nodes data: " + res.stderr)

    # Parse JSON manually is hard without stdlib; but ctx.run returns JSON as text.
    # Since we have no json module, and Starlark cannot parse JSON, we assume
    # the response is JSON and pass it as a string. However, original module returns dict.
    # Because Starlark lacks JSON parsing and the environment is restricted,
    # this module cannot be fully faithful without external help.
    # We fail with a clear message indicating limitation.
    fail("lxca_nodes module cannot return JSON-parsed dict in Starlark (no json module available). Use raw response via ctx.run('curl ...') and parse externally.")

    # The above fail() ensures the module does not pretend to parse JSON,
    # since the Starlark runtime cannot parse JSON without external libraries.
    # In practice, this module should be implemented in Python or use a helper.
    # Returning raw text as "result" is not possible because the return contract expects dict.
    # The fail() above is the only responsible behavior under the constraints.

    # Note: If a future environment adds JSON parsing builtins, they would be used here.
    # For now, this translation highlights a fundamental limitation.
