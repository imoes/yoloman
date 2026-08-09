def main(ctx, params):
    name = params["name"]
    client_id = params["client_id"]
    realm = params["realm"]
    url = params["auth_keycloak_url"]
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_realm = params.get("auth_realm")
    username = params.get("auth_username")
    password = params.get("auth_password")
    client_secret = params.get("auth_client_secret")
    token = params.get("token")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Build headers for requests
    headers = {"User-Agent": http_agent}

    # Determine authentication method
    if token == None:
        if not (auth_realm and username and password):
            fail("one of token or (auth_realm + auth_username + auth_password) is required")
        # Obtain token via password grant
        token_url = url.rstrip("/") + "/realms/" + auth_realm + "/protocol/openid-connect/token"
        payload = (
            "grant_type=password&client_id=" + auth_client_id +
            "&username=" + username + "&password=" + password
        )
        if client_secret != None:
            payload += "&client_secret=" + client_secret
        res = ctx.run(
            [
                "curl", "-s", "-X", "POST", token_url,
                "-H", "Content-Type: application/x-www-form-urlencoded",
                "-d", payload,
            ] + (["--insecure"] if not validate_certs else []),
            mutates=False
        )
        if res.rc != 0:
            fail("failed to obtain token: " + res.stderr)
        # Parse JSON manually (no json module)
        token_str = res.stdout.strip()
        if not token_str.startswith('{"'):
            fail("unexpected token response: " + token_str)
        # Extract access_token field by simple string search
        token_key = '"access_token":"'
        start = token_str.find(token_key)
        if start == -1:
            fail("cannot parse access_token from response")
        start += len(token_key)
        end = token_str.find('"', start)
        if end == -1:
            fail("cannot parse access_token from response")
        token = token_str[start:end]
    headers["Authorization"] = "Bearer " + token

    # Get client ID (from name to internal id)
    clients_url = url.rstrip("/") + "/admin/realms/" + realm + "/clients"
    res = ctx.run(
        [
            "curl", "-s", "-G", clients_url,
            "-H", "Content-Type: application/json",
        ] + ([("--insecure")] if not validate_certs else []),
        mutates=False
    )
    if res.rc != 0:
        fail("failed to list clients: " + res.stderr)
    clients_json = res.stdout.strip()
    # Simple JSON parser for array of objects with clientId field
    client_id_found = ""
    # Look for {"clientId":"..."}
    i = 0
    while i < len(clients_json):
        idx = clients_json.find('"clientId":"', i)
        if idx == -1:
            break
        start_name = idx + len('"clientId":"')
        end_name = clients_json.find('"', start_name)
        if end_name == -1:
            break
        c_id = clients_json[start_name:end_name]
        if c_id == client_id:
            # Extract "id" field for this client
            # Find the preceding '{'
            brace = clients_json.rfind('{', max(0, idx - 200), idx)
            if brace == -1:
                break
            # Look for "id":"..." after brace
            id_key = '"id":"'
            j = brace
            while True:
                id_idx = clients_json.find(id_key, j)
                if id_idx == -1 or id_idx > end_name:
                    break
                start_id = id_idx + len(id_key)
                end_id = clients_json.find('"', start_id)
                if end_id == -1:
                    break
                client_id_found = clients_json[start_id:end_id]
                break
            if client_id_found:
                break
        i = end_name + 1
    if not client_id_found:
        fail("client not found: " + client_id)

    # Get permissions by name
    perms_url = (
        url.rstrip("/") +
        "/admin/realms/" + realm +
        "/clients/" + client_id_found +
        "/authz/resource-server/permission"
    )
    res = ctx.run(
        [
            "curl", "-s", "-G", perms_url,
            "-H", "Content-Type: application/json",
            "-d", "name=" + name,
        ] + ([("--insecure")] if not validate_certs else []),
        mutates=False
    )
    if res.rc != 0:
        fail("failed to query permissions: " + res.stderr)
    perms_json = res.stdout.strip()

    # Parse permissions array; extract first matching permission by name
    permission = {}
    # Scan for objects with matching name field
    i = 0
    while i < len(perms_json):
        brace = perms_json.find('{', i)
        if brace == -1:
            break
        # Look for "name":"..." inside this object
        name_key = '"name":"'
        idx = perms_json.find(name_key, brace)
        if idx != -1:
            start_name = idx + len(name_key)
            end_name = perms_json.find('"', start_name)
            if end_name != -1:
                perm_name = perms_json[start_name:end_name]
                if perm_name == name:
                    # Extract full object text
                    # Find matching brace
                    depth = 0
                    j = brace
                    while j < len(perms_json):
                        if perms_json[j] == '{':
                            depth += 1
                        elif perms_json[j] == '}':
                            depth -= 1
                            if depth == 0:
                                permission_str = perms_json[brace:j+1]
                                # Parse into dict manually
                                permission = parse_dict(permission_str)
                                break
                        j += 1
                    break
        i = brace + 1

    return {
        "changed": False,
        "msg": "permission queried",
        "queried_state": permission
    }


def parse_dict(s):
    """Simple JSON object parser for flat key-value pairs with string values."""
    d = {}
    i = 1  # skip leading {
    while i < len(s) - 1:
        # Skip whitespace and commas
        while i < len(s) and s[i] in " \t\n\r,":
            i += 1
        if i >= len(s) - 1:
            break
        # Expect key string
        if s[i] != '"':
            break
        i += 1
        key_start = i
        while i < len(s) and s[i] != '"':
            i += 1
        key = s[key_start:i]
        i += 1  # skip closing "
        # Skip whitespace and colon
        while i < len(s) and s[i] in " \t\n\r:":
            i += 1
        # Expect value string
        if s[i] != '"':
            break
        i += 1
        val_start = i
        while i < len(s) and s[i] != '"':
            i += 1
        val = s[val_start:i]
        i += 1  # skip closing "
        d[key] = val
    return d
