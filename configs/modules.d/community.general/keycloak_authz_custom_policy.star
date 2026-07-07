def main(ctx, params):
    # Required params
    realm = params["realm"]
    client_id = params["client_id"]
    name = params["name"]
    policy_type = params["policy_type"]
    state = params.get("state", "present")

    # Auth params
    auth_url = params["auth_keycloak_url"]
    auth_realm = params.get("auth_realm")
    auth_user = params.get("auth_username")
    auth_pass = params.get("auth_password")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_client_secret = params.get("auth_client_secret")
    token = params.get("token")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Validate required auth combination if token not provided
    if token == None:
        if auth_user == None or auth_pass == None or auth_realm == None:
            fail("Either token or (auth_username, auth_password, auth_realm) must be provided")

    # Get token if not provided
    headers = {}
    if token != None:
        headers["Authorization"] = "Bearer " + token
    else:
        # Get token via password grant
        auth_url_norm = auth_url.rstrip("/")
        payload_parts = [
            "client_id=" + auth_client_id,
            "username=" + auth_user,
            "password=" + auth_pass,
            "grant_type=password",
            "scope=openid",
        ]
        if auth_client_secret != None:
            payload_parts += ["client_secret=" + auth_client_secret]
        if auth_realm != None:
            payload_parts += ["realm=" + auth_realm]

        curl_args = [
            "curl", "-s", "--connect-timeout", str(connection_timeout),
            "-H", "Content-Type: application/x-www-form-urlencoded",
            "-H", "User-Agent: " + http_agent,
        ] + (["--cacert", "/dev/null"] if not validate_certs else [])
        for part in payload_parts:
            curl_args += ["-d", part]
        curl_args += [auth_url_norm + "/realms/master/protocol/openid-connect/token"]

        token_resp = ctx.run(curl_args, mutates=False)
        if token_resp.rc != 0:
            fail("Failed to obtain token from Keycloak: " + token_resp.stderr)

        # Parse JSON manually
        token_data = {}
        for line in token_resp.stdout.split("\n"):
            if "=" in line:
                k, v = line.split("=", 1)
                token_data[k.strip()] = v.strip()
        access_token = token_data.get("access_token", "")
        headers["Authorization"] = "Bearer " + access_token

    # Helper to call Keycloak API (no try/except — use fail on error)
    def keycloak_api(method, path, payload=None, ok_codes=[200]):
        url = auth_url_norm + path
        args = [
            "curl", "-s", "--connect-timeout", str(connection_timeout),
            "-H", "Content-Type: application/json",
            "-H", "User-Agent: " + http_agent,
        ] + (["--cacert", "/dev/null"] if not validate_certs else [])
        for k, v in headers.items():
            args += ["-H", k + ": " + v]
        args += ["-X", method, url]
        if payload != None:
            args += ["-d", payload]
        res = ctx.run(args, mutates=False)
        if res.rc not in ok_codes:
            fail("Keycloak API call failed (%s %s): %s" % (method, url, res.stderr))
        if res.stdout == "":
            return None
        return res.stdout

    # Get client ID by clientId
    path = "/admin/realms/" + realm + "/clients?clientId=" + client_id
    res = keycloak_api("GET", path, ok_codes=[200])
    if res == None:
        fail("Client %s not found in realm %s" % (client_id, realm))

    # Parse client ID — extract 'id' from JSON
    cid = ""
    # Basic search for "id": "value"
    search_str = '"id":'
    idx = res.find(search_str)
    if idx != -1:
        start = idx + len(search_str)
        # Skip whitespace and quote
        while start < len(res) and (res[start] == ' ' or res[start] == '\t' or res[start] == '"'):
            start += 1
        end = start
        while end < len(res) and res[end] != '"':
            end += 1
        if end > start:
            cid = res[start:end]

    if cid == "":
        fail("Failed to extract client ID from response for client %s" % client_id)

    # Get existing policies
    path = "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/policy/scoped"
    res = keycloak_api("GET", path, ok_codes=[200])
    found_policy = None
    if res != None:
        # Scan for policy with matching name
        # Basic JSON array parsing: look for 'name": "..."'
        search_name = '"name": "' + name + '"'
        idx = res.find(search_name)
        if idx != -1:
            # Extract 'id' of the policy object containing this name
            # Search backwards for nearest '"id":'
            search_id = '"id":'
            start_scan = max(0, idx - 2000)  # reasonable window
            id_idx = res.rfind(search_id, start_scan, idx)
            if id_idx != -1:
                start_id = id_idx + len(search_id)
                while start_id < len(res) and (res[start_id] == ' ' or res[start_id] == '\t' or res[start_id] == '"'):
                    start_id += 1
                end_id = start_id
                while end_id < len(res) and res[end_id] != '"':
                    end_id += 1
                policy_id = res[start_id:end_id]
                found_policy = {"id": policy_id, "name": name, "type": policy_type}

    # State logic
    if state == "present":
        if found_policy != None:
            # Already exists — no update supported per original module
            return {"changed": False, "msg": "Custom policy " + name + " already exists", "data": {"end_state": {"name": name, "policy_type": policy_type}}}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "Would create custom policy " + name, "data": {"end_state": {"name": name, "policy_type": policy_type}}}
            else:
                # Create policy
                payload = '{"name": "' + name + '", "type": "' + policy_type + '", "logic": "POSITIVE", "enabled": true, "decisionStrategy": "UNANIMOUS"}'
                path = "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/policy"
                keycloak_api("POST", path, payload=payload, ok_codes=[201, 200])
                return {"changed": True, "msg": "Custom policy " + name + " created", "data": {"end_state": {"name": name, "policy_type": policy_type}}}

    elif state == "absent":
        if found_policy == None:
            return {"changed": False, "msg": "Custom policy " + name + " does not exist"}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "Would remove custom policy " + name, "data": {"end_state": {}}}
            else:
                # Delete policy
                path = "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/policy/" + found_policy["id"]
                keycloak_api("DELETE", path, ok_codes=[204])
                return {"changed": True, "msg": "Custom policy " + name + " removed", "data": {"end_state": {}}}

    fail("Unsupported state: " + state)
