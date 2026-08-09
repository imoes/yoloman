def main(ctx, params):
    # Required params
    auth_keycloak_url = params["auth_keycloak_url"]
    realm = params.get("realm", "master")
    client_id_param = params.get("client_id")
    client_id_alias = params.get("clientId")
    client_id = client_id_param or client_id_alias  # prefer 'client_id', fallback to 'clientId' alias

    # Optional auth params
    token = params.get("token")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_realm = params.get("auth_realm")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_client_secret = params.get("auth_client_secret")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Determine client_id or id
    client_id_or_alias = params.get("client_id") or params.get("clientId")
    id_param = params.get("id")
    if id_param == None and client_id_or_alias == None:
        fail("Either 'id' or 'client_id' (or 'clientId') must be provided")

    # Build auth header
    auth_header = None
    if token != None:
        auth_header = "Bearer " + token
    else:
        # username/password auth
        if auth_username == None or auth_password == None:
            fail("Authentication requires either 'token' or both 'auth_username' and 'auth_password'")
        # Prepare form body for token request
        form_data = [
            "client_id=" + auth_client_id,
            "username=" + auth_username,
            "password=" + auth_password,
            "grant_type=password"
        ]
        if auth_realm != None:
            form_data.append("realm=" + auth_realm)
        if auth_client_secret != None:
            form_data.append("client_secret=" + auth_client_secret)

        # Call token endpoint
        token_realm = auth_realm if auth_realm else "master"
        token_url = auth_keycloak_url.rstrip("/") + "/realms/" + token_realm + "/protocol/openid-connect/token"
        res = ctx.run([
            "curl", "-s", "-X", "POST", "-H", "Content-Type: application/x-www-form-urlencoded",
            "-d", "&".join(form_data), token_url
        ])
        if res.rc != 0:
            fail("Failed to obtain access token: " + res.stderr)
        token_json = res.stdout
        # Basic JSON parsing without json module: find "access_token":"..."
        token_start = token_json.find('"access_token":"')
        if token_start == -1:
            fail("Could not find access_token in token response")
        token_start += len('"access_token":"')
        token_end = token_json.find('"', token_start)
        if token_end == -1:
            fail("Malformed access_token in token response")
        token = token_json[token_start:token_end]
        auth_header = "Bearer " + token

    # Resolve client id if only client_id (not id) provided
    resolved_id = id_param
    if resolved_id == None and client_id_or_alias != None:
        # Fetch client list to find id by client_id
        clients_url = auth_keycloak_url.rstrip("/") + "/admin/realms/" + realm + "/clients"
        headers = ["-H", "Authorization: " + auth_header]
        if not validate_certs:
            headers.extend(["-k"])
        headers.extend(["-H", "User-Agent: " + http_agent])
        headers.extend(["-H", "Accept: application/json"])

        res = ctx.run(["curl", "-s", "-G"] + headers + [clients_url], ok_codes=[0, 401, 403])
        if res.rc != 0:
            fail("Failed to list clients: " + res.stderr)
        # Simple JSON parsing: find client with 'clientId' == provided client_id
        clients_str = res.stdout
        # Extract all client entries: naive parsing of JSON array
        if not clients_str.startswith("[") or not clients_str.endswith("]"):
            fail("Unexpected clients list format")
        # Strip outer brackets
        inner = clients_str[1:-1].strip()
        if not inner:
            fail("No clients found in realm " + realm)
        # Replace '},{' with '}\n{'
        inner = inner.replace("},{", "}\n{")
        found = False
        for client_block in inner.split("\n"):
            client_block = client_block.strip()
            if not client_block.startswith("{") or not client_block.endswith("}"):
                continue
            # Extract 'id' and 'clientId'
            id_match = '"id":"'
            cid_match = '"clientId":"'
            id_start = client_block.find(id_match)
            cid_start = client_block.find(cid_match)
            if id_start == -1 or cid_start == -1:
                continue
            id_start += len(id_match)
            id_end = client_block.find('"', id_start)
            if id_end == -1:
                continue
            cid_start += len(cid_match)
            cid_end = client_block.find('"', cid_start)
            if cid_end == -1:
                continue
            client_id_val = client_block[cid_start:cid_end]
            if client_id_val == client_id_or_alias:
                resolved_id = client_block[id_start:id_end]
                found = True
                break
        if not found:
            fail("Client not found with client_id: " + str(client_id_or_alias))

    # In check_mode, return dummy secret
    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "New client secret would be generated for ID " + resolved_id,
            "data": {
                "end_state": {
                    "type": "secret",
                    "value": "X" * 32
                }
            }
        }

    # Regenerate client secret
    regenerate_url = auth_keycloak_url.rstrip("/") + "/admin/realms/" + realm + "/clients/" + resolved_id + "/client-secret"
    headers = ["-H", "Authorization: " + auth_header]
    if not validate_certs:
        headers.extend(["-k"])
    headers.extend(["-H", "User-Agent: " + http_agent])
    headers.extend(["-X", "POST"])

    res = ctx.run(["curl", "-s"] + headers + [regenerate_url], ok_codes=[200])
    if res.rc != 0:
        fail("Failed to regenerate client secret: " + res.stderr)

    # Parse response for 'value'
    secret_json = res.stdout
    # Extract 'value' from {"value":"..."}
    val_start = secret_json.find('"value":"')
    if val_start == -1:
        fail("Secret response missing 'value' field")
    val_start += len('"value":"')
    val_end = secret_json.find('"', val_start)
    if val_end == -1:
        fail("Malformed secret value")
    secret_value = secret_json[val_start:val_end]

    return {
        "changed": True,
        "msg": "New client secret has been generated for ID " + resolved_id,
        "data": {
            "end_state": {
                "type": "secret",
                "value": secret_value
            }
        }
    }
