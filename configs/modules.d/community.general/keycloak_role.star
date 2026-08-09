def main(ctx, params):
    # Required parameters
    name = params["name"]
    state = params.get("state", "present")
    realm = params.get("realm", "master")
    client_id = params.get("client_id")

    # Authentication parameters
    auth_url = params["auth_keycloak_url"].rstrip("/")
    auth_realm = params.get("auth_realm", "master")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    username = params.get("auth_username")
    password = params.get("auth_password")
    token = params.get("token")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Build headers
    headers = {
        "Content-Type": "application/json",
        "User-Agent": http_agent,
    }

    # Get token if not provided
    if token == None:
        if username == None or password == None:
            fail("Either token or auth_username/auth_password must be provided")
        auth_url_full = auth_url + "/realms/" + auth_realm + "/protocol/openid-connect/token"
        body = (
            "grant_type=password"
            + "&client_id=" + auth_client_id
            + "&username=" + username
            + "&password=" + password
        )
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-d", body, "-H", "Content-Type: application/x-www-form-urlencoded", auth_url_full],
            mutates=False
        )
        if res.rc != 0:
            fail("Failed to obtain token: " + res.stderr)
        token_data = res.stdout
        # Extract access_token using simple string parsing
        token_start = token_data.find('"access_token":"') + len('"access_token":"')
        token_end = token_data.find('"', token_start)
        if token_start < len('"access_token":"') or token_end == -1:
            fail("Could not parse access_token from response")
        token = token_data[token_start:token_end]

    headers["Authorization"] = "Bearer " + token

    # Build role path
    if client_id == None:
        role_path = auth_url + "/admin/realms/" + realm + "/roles/" + name
    else:
        # Get client ID for client roles
        clients_res = ctx.run(
            ["curl", "-s", "-H", "Authorization: Bearer " + token, auth_url + "/admin/realms/" + realm + "/clients?clientId=" + client_id],
            mutates=False
        )
        if clients_res.rc != 0:
            fail("Failed to query clients: " + clients_res.stderr)
        clients = clients_res.stdout
        if '"id":"' in clients:
            client_id_value = clients.split('"id":"')[1].split('"')[0]
        else:
            fail("Client " + client_id + " not found")
        role_path = auth_url + "/admin/realms/" + realm + "/clients/" + client_id_value + "/roles"

    # Fetch existing role
    res = ctx.run(
        ["curl", "-s", "-H", "Authorization: Bearer " + token, role_path],
        mutates=False
    )
    existing = None
    if res.rc == 0:
        existing = res.stdout

    # Handle absent state
    if state == "absent":
        if existing == None or existing == "":
            return {"changed": False, "msg": "Role does not exist, doing nothing."}
        if ctx.check_mode:
            return {"changed": True, "msg": "Would delete role " + name}
        del_res = ctx.run(
            ["curl", "-s", "-X", "DELETE", "-H", "Authorization: Bearer " + token, role_path],
            mutates=True
        )
        if del_res.rc != 0:
            fail("Failed to delete role: " + del_res.stderr)
        return {"changed": True, "msg": "Role " + name + " has been deleted"}

    # Build desired role payload
    role = {"name": name}

    # Description
    if params.get("description") != None:
        role["description"] = params["description"]

    # Attributes
    if params.get("attributes") != None:
        attrs = {}
        for k, v in params["attributes"].items():
            if type(v) == "string":
                attrs[k] = [v]
            else:
                attrs[k] = v
        role["attributes"] = attrs

    # Composite role support (basic)
    composite = params.get("composite", False)
    if composite == True:
        role["composite"] = True

    composites_list = params.get("composites", [])
    if len(composites_list) > 0:
        # Parse existing composites if present (simplified)
        existing_composites = []
        if existing != None and existing != "":
            if '"composites":' in existing:
                composites_str = existing.split('"composites":[')[1].split(']')[0] + "]"
                if composites_str != "[]":
                    for item in composites_str.split("{"):
                        if '"name":' in item:
                            existing_composites.append(item.split('"name":"')[1].split('"')[0])

        new_composites = []
        for comp in composites_list:
            comp_name = comp["name"]
            comp_client_id = comp.get("client_id")
            comp_state = comp.get("state", "present")
            if comp_state == "absent":
                continue
            if comp_name not in existing_composites:
                new_composites.append(comp)

        if len(new_composites) > 0:
            # Add composites via separate endpoint (simplified: just mark for update)
            role["composites"] = new_composites

    # Determine if update needed
    changed = False
    if existing == None or existing == "":
        changed = True
    else:
        # Compare key fields
        if params.get("description") != None:
            if ('"description":"' + params["description"] + '"') not in existing:
                changed = True
        if params.get("attributes") != None:
            changed = True  # Simplified: always update if attributes are provided
        if composite == True and '"composite":false' in existing:
            changed = True

    # Apply changes
    if changed:
        if ctx.check_mode:
            return {"changed": True, "msg": "Would " + ("create" if existing == None else "update") + " role " + name}

        if existing == None or existing == "":
            # Create
            post_res = ctx.run(
                ["curl", "-s", "-X", "POST", "-H", "Authorization: Bearer " + token, "-d", str(role), role_path],
                mutates=True
            )
            if post_res.rc != 0:
                fail("Failed to create role: " + post_res.stderr + " | " + str(role))
            return {"changed": True, "msg": "Role " + name + " has been created"}

        # Update
        put_res = ctx.run(
            ["curl", "-s", "-X", "PUT", "-H", "Authorization: Bearer " + token, "-d", str(role), role_path],
            mutates=True
        )
        if put_res.rc != 0:
            fail("Failed to update role: " + put_res.stderr)
        return {"changed": True, "msg": "Role " + name + " has been updated"}

    # No changes
    return {"changed": False, "msg": "Role " + name + " is already in desired state"}
