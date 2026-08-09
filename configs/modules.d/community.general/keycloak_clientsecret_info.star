def main(ctx, params):
    # Extract required and optional parameters
    auth_url = params["auth_keycloak_url"]
    realm = params.get("realm", "master")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    token = params.get("token")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_client_secret = params.get("auth_client_secret")
    auth_realm = params.get("auth_realm")
    client_id = params.get("client_id")
    client_id_alias = params.get("clientId")
    if client_id_alias != None and client_id == None:
        client_id = client_id_alias
    id_val = params.get("id")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Validation
    if token == None:
        if auth_username == None:
            fail("Either token or auth_username must be provided")
        if auth_password == None:
            fail("Either token or auth_password must be provided")

    # Helper: build authorization header
    def build_auth_header():
        if token != None:
            return {"Authorization": "Bearer " + token}
        # Token request via password grant
        body = {
            "client_id": auth_client_id,
            "username": auth_username,
            "password": auth_password,
            "grant_type": "password"
        }
        if auth_realm != None:
            body["realm"] = auth_realm
        if auth_client_secret != None:
            body["client_secret"] = auth_client_secret

        headers = {
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": http_agent
        }

        # Construct request body as form-encoded string (simple manual encoding)
        form_data = []
        for k, v in body.items():
            if v != None:
                form_data.append(k + "=" + str(v).replace(" ", "%20"))
        data = "&".join(form_data)

        # Perform token request
        # Assume standard Keycloak path: /realms/{auth_realm}/protocol/openid-connect/token
        # If auth_realm is missing, default to master
        token_realm = auth_realm if auth_realm != None else "master"
        token_url = auth_url.rstrip("/") + "/realms/" + token_realm + "/protocol/openid-connect/token"

        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/x-www-form-urlencoded",
             "-H", "User-Agent: " + http_agent,
             "--connect-timeout", str(connection_timeout),
             "-d", data,
             token_url],
            mutates=False
        )
        if res.rc != 0:
            fail("Failed to obtain access token: " + res.stderr)
        stdout = res.stdout
        if "access_token" not in stdout:
            fail("Token endpoint did not return access_token")

        # Extract token: naive parsing for "access_token":"..."
        token_key = '"access_token":"'
        start_idx = stdout.find(token_key)
        if start_idx == -1:
            fail("Could not parse access_token from response")
        start_idx += len(token_key)
        end_idx = stdout.find('"', start_idx)
        if end_idx == -1:
            fail("Could not parse access_token from response")
        access_token = stdout[start_idx:end_idx]
        return {"Authorization": "Bearer " + access_token}

    auth_headers = build_auth_header()

    # Determine client ID if not provided
    client_id_for_endpoint = id_val
    if client_id_for_endpoint == None:
        if client_id == None:
            fail("Either id or client_id must be provided")
        # Lookup client_id to id via API
        query_url = auth_url.rstrip("/") + "/admin/realms/" + realm + "/clients?clientId=" + client_id
        curl_cmd = [
            "curl", "-s", "-X", "GET",
            "-H", "Authorization: Bearer " + auth_headers["Authorization"],
            "-H", "User-Agent: " + http_agent,
            "--connect-timeout", str(connection_timeout),
            query_url
        ]
        if not validate_certs:
            curl_cmd.insert(5, "-k")
        res = ctx.run(curl_cmd, mutates=False)
        if res.rc != 0:
            fail("Failed to lookup client by clientId: " + res.stderr)
        stdout = res.stdout

        # Expect JSON array; parse first element's id field
        if "[" not in stdout or "]" not in stdout:
            fail("Unexpected response when looking up client by clientId")
        obj_start = stdout.find("{")
        obj_end = stdout.rfind("}") + 1
        if obj_start == -1 or obj_end == -1:
            fail("Could not parse client JSON")
        obj_str = stdout[obj_start:obj_end]

        # Extract "id":"..."
        id_key = '"id":"'
        idx = obj_str.find(id_key)
        if idx == -1:
            fail("Client object missing 'id' field")
        idx += len(id_key)
        end_idx = obj_str.find('"', idx)
        if end_idx == -1:
            fail("Could not parse client id")
        client_id_for_endpoint = obj_str[idx:end_idx]

    # Now get client secret
    # GET /admin/realms/{realm}/clients/{id}/client-secret
    secret_url = auth_url.rstrip("/") + "/admin/realms/" + realm + "/clients/" + client_id_for_endpoint + "/client-secret"

    curl_cmd = [
        "curl", "-s", "-X", "GET",
        "-H", "Authorization: Bearer " + auth_headers["Authorization"],
        "-H", "User-Agent: " + http_agent,
        "--connect-timeout", str(connection_timeout),
        secret_url
    ]
    if not validate_certs:
        curl_cmd.insert(5, "-k")

    res = ctx.run(curl_cmd, mutates=False)
    if res.rc != 0:
        fail("Failed to retrieve client secret: " + res.stderr)

    stdout = res.stdout

    # Parse JSON manually
    obj_start = stdout.find("{")
    obj_end = stdout.rfind("}") + 1
    if obj_start == -1 or obj_end == -1:
        fail("Unexpected client secret response format")
    obj_str = stdout[obj_start:obj_end]

    # Extract type
    type_key = '"type":"'
    idx = obj_str.find(type_key)
    if idx == -1:
        fail("Client secret object missing 'type' field")
    idx += len(type_key)
    end_idx = obj_str.find('"', idx)
    if end_idx == -1:
        fail("Could not parse type")
    secret_type = obj_str[idx:end_idx]

    # Extract value
    value_key = '"value":"'
    idx = obj_str.find(value_key)
    if idx == -1:
        fail("Client secret object missing 'value' field")
    idx += len(value_key)
    end_idx = obj_str.find('"', idx)
    if end_idx == -1:
        fail("Could not parse value")
    secret_value = obj_str[idx:end_idx]

    # Success
    result = {
        "changed": False,
        "msg": "Get client secret successful for ID " + client_id_for_endpoint,
        "data": {
            "clientsecret_info": {
                "type": secret_type,
                "value": secret_value
            }
        }
    }
    return result
