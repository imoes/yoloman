def main(ctx, params):
    # Extract parameters
    name = params["name"]
    state = params.get("state", "present")
    display_name = params.get("display_name")
    icon_uri = params.get("icon_uri")
    client_id = params["client_id"]
    realm = params["realm"]
    keycloak_url = params["auth_keycloak_url"]
    auth_realm = params.get("auth_realm")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    token = params.get("token")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Build headers
    headers = {"User-Agent": http_agent, "Content-Type": "application/json"}

    # Get access token
    access_token = None
    if token != None:
        access_token = token
    elif auth_realm != None and auth_username != None and auth_password != None:
        payload = (
            "client_id=" + auth_client_id +
            "&grant_type=password" +
            "&username=" + auth_username +
            "&password=" + auth_password +
            ("&realm=" + auth_realm if auth_realm else "")
        )
        url = keycloak_url + "/realms/" + (auth_realm if auth_realm else "master") + "/protocol/openid-connect/token"
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/x-www-form-urlencoded",
             "-d", payload, url],
            mutates=False,
        )
        if res.rc != 0:
            fail("Failed to obtain token: " + res.stderr)
        token_json = res.stdout.strip()
        # Basic JSON parse: extract access_token
        prefix = '"access_token":"'
        start = token_json.find(prefix)
        if start == -1:
            fail("Token response missing access_token field")
        start += len(prefix)
        end = token_json.find('"', start)
        if end == -1:
            fail("Malformed token response")
        access_token = token_json[start:end]
    else:
        fail("Either token or auth_realm + auth_username + auth_password must be provided")

    if access_token == None:
        fail("Authentication token not obtained")

    headers["Authorization"] = "Bearer " + access_token

    # Get client ID by clientId
    url = keycloak_url + "/admin/realms/" + realm + "/clients?clientId=" + client_id
    res = ctx.run(
        ["curl", "-s", "-X", "GET", "-H", "Content-Type: application/json", "-H",
         "Authorization: Bearer " + access_token, url],
        mutates=False,
    )
    if res.rc != 0:
        fail("Failed to query client: " + res.stderr)
    clients = res.stdout.strip()
    # Parse JSON manually: look for object with clientId matching
    cid = None
    if clients.startswith("["):
        i = 0
        while i < len(clients):
            if clients[i:i+10] == '"clientId"':
                eq_start = clients.find('"', i+10) + 1
                eq_end = clients.find('"', eq_start)
                if eq_end == -1:
                    break
                found_client_id = clients[eq_start:eq_end]
                if found_client_id == client_id:
                    obj_start = clients.rfind("{", 0, i)
                    obj_end = clients.find("}", i)
                    if obj_end == -1:
                        break
                    obj_str = clients[obj_start:obj_end+1]
                    id_key = '"id":"'
                    id_start = obj_str.find(id_key)
                    if id_start != -1:
                        id_start += len(id_key)
                        id_end = obj_str.find('"', id_start)
                        if id_end != -1:
                            cid = obj_str[id_start:id_end]
                            break
            i += 1
    if cid == None:
        fail("Client " + client_id + " not found in realm " + realm)

    # Get existing authorization scope
    url = keycloak_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/scope?name=" + name
    res = ctx.run(
        ["curl", "-s", "-X", "GET", "-H", "Content-Type: application/json", "-H",
         "Authorization: Bearer " + access_token, url],
        mutates=False,
    )
    if res.rc != 0:
        fail("Failed to query authorization scope: " + res.stderr)
    scopes_str = res.stdout.strip()

    before_scope = None
    if scopes_str.startswith("[") and scopes_str != "[]":
        obj_start = scopes_str.find("{")
        if obj_start != -1:
            brace_count = 0
            obj_end = obj_start
            for i in range(obj_start, len(scopes_str)):
                if scopes_str[i] == '{':
                    brace_count += 1
                elif scopes_str[i] == '}':
                    brace_count -= 1
                    if brace_count == 0:
                        obj_end = i + 1
                        break
            scope_obj = scopes_str[obj_start:obj_end]
            def get_field(s, key):
                prefix = '"' + key + '":"'
                idx = s.find(prefix)
                if idx == -1:
                    return None
                val_start = idx + len(prefix)
                val_end = s.find('"', val_start)
                if val_end == -1:
                    return None
                return s[val_start:val_end]

            before_scope = {}
            bid = get_field(scope_obj, "id")
            if bid != None:
                before_scope["id"] = bid
            bname = get_field(scope_obj, "name")
            if bname != None:
                before_scope["name"] = bname
            bdisplay = get_field(scope_obj, "displayName")
            if bdisplay != None:
                before_scope["displayName"] = bdisplay
            bicon = get_field(scope_obj, "iconUri")
            if bicon != None:
                before_scope["iconUri"] = bicon

    # Build desired payload
    desired_scope = {"name": name}
    if display_name == None:
        desired_scope["displayName"] = ""
    else:
        desired_scope["displayName"] = display_name
    if icon_uri == None:
        desired_scope["iconUri"] = ""
    else:
        desired_scope["iconUri"] = icon_uri

    # Ensure empty strings for missing optional fields
    for k in ["displayName", "iconUri"]:
        if k not in desired_scope or desired_scope[k] == None:
            desired_scope[k] = ""

    # Ensure before_scope fields present
    if before_scope != None:
        for k in ["displayName", "iconUri"]:
            if k not in before_scope:
                before_scope[k] = ""

    # Handle state
    if state == "present":
        if before_scope != None:
            # Check for changes
            changes = False
            for k in ["name", "displayName", "iconUri"]:
                if before_scope.get(k, "") != desired_scope.get(k, ""):
                    changes = True
                    break
            if not changes:
                return {"changed": False, "msg": "Authorization scope not updated", "data": {"end_state": before_scope}}

            if ctx.check_mode:
                return {"changed": True, "msg": "Authorization scope would be updated"}

            # Update
            desired_scope["id"] = before_scope["id"]
            url = keycloak_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/scope/" + before_scope["id"]
            payload_str = '{"name":"%(name)s","displayName":"%(displayName)s","iconUri":"%(iconUri)s"}' % {
                "name": desired_scope["name"].replace('"', '\\"'),
                "displayName": desired_scope["displayName"].replace('"', '\\"'),
                "iconUri": desired_scope["iconUri"].replace('"', '\\"'),
            }
            res = ctx.run(
                ["curl", "-s", "-X", "PUT", "-H", "Content-Type: application/json",
                 "-H", "Authorization: Bearer " + access_token, "-d", payload_str, url],
                mutates=True,
            )
            if res.skipped:
                return {"changed": True, "msg": "Authorization scope would be updated"}
            if res.rc != 0:
                fail("Failed to update authorization scope: " + res.stderr)
            return {"changed": True, "msg": "Authorization scope updated", "data": {"end_state": desired_scope}}
        else:
            # Create new scope
            if ctx.check_mode:
                return {"changed": True, "msg": "Authorization scope would be created"}

            url = keycloak_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/scope"
            payload_str = '{"name":"%(name)s","displayName":"%(displayName)s","iconUri":"%(iconUri)s"}' % {
                "name": desired_scope["name"].replace('"', '\\"'),
                "displayName": desired_scope["displayName"].replace('"', '\\"'),
                "iconUri": desired_scope["iconUri"].replace('"', '\\"'),
            }
            res = ctx.run(
                ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
                 "-H", "Authorization: Bearer " + access_token, "-d", payload_str, url],
                mutates=True,
            )
            if res.skipped:
                return {"changed": True, "msg": "Authorization scope would be created"}
            if res.rc != 0:
                fail("Failed to create authorization scope: " + res.stderr)
            return {"changed": True, "msg": "Authorization scope created", "data": {"end_state": desired_scope}}

    elif state == "absent":
        if before_scope != None:
            if ctx.check_mode:
                return {"changed": True, "msg": "Authorization scope would be removed"}

            url = keycloak_url + "/admin/realms/" + realm + "/clients/" + cid + "/authz/resource-server/scope/" + before_scope["id"]
            res = ctx.run(
                ["curl", "-s", "-X", "DELETE", "-H", "Authorization: Bearer " + access_token, url],
                mutates=True,
            )
            if res.skipped:
                return {"changed": True, "msg": "Authorization scope would be removed"}
            if res.rc != 0:
                fail("Failed to delete authorization scope: " + res.stderr)
            return {"changed": True, "msg": "Authorization scope removed"}
        else:
            return {"changed": False, "msg": "Authorization scope not found"}
    else:
        fail("Unsupported state: " + state)
