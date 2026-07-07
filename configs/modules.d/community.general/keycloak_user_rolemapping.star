def main(ctx, params):
    # Extract parameters
    auth_keycloak_url = params["auth_keycloak_url"]
    auth_realm = params.get("auth_realm", "master")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_client_secret = params.get("auth_client_secret")
    token = params.get("token")
    realm = params.get("realm", "master")
    target_username = params.get("target_username")
    uid = params.get("uid")
    service_account_user_client_id = params.get("service_account_user_client_id")
    client_id = params.get("client_id")
    cid = params.get("cid")
    roles = params.get("roles")
    state = params.get("state", "present")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Basic validation: at least one user identifier
    if uid == None and target_username == None and service_account_user_client_id == None:
        ctx.fail("Either uid, target_username, or service_account_user_client_id must be specified.")

    # Get user id
    if uid == None:
        if target_username != None:
            auth_args = []
            if auth_username and auth_password and not token:
                auth_args = ["-u", auth_username + ":" + auth_password]
            curl_cmd = (
                ["curl", "-s", "-X", "GET", "--connect-timeout", str(connection_timeout), "--user-agent", http_agent]
                + auth_args
                + ["-H", "Authorization: Bearer " + token] if token else []
            )
            curl_cmd = (
                ["curl", "-s", "-X", "GET"]
                + (["-H", "Authorization: Bearer " + token] if token else [])
                + (["-u", auth_username + ":" + auth_password] if auth_username and auth_password and not token else [])
                + ["--connect-timeout", str(connection_timeout), "--user-agent", http_agent]
                + [auth_keycloak_url + "/admin/realms/" + realm + "/users?username=" + target_username]
            )
            res = ctx.run(curl_cmd, mutates=False)
            if res.rc != 0:
                ctx.fail("Failed to fetch user: " + res.stderr)
            users = res.stdout.strip()
            if users == "[]" or users == "":
                ctx.fail("User not found: " + target_username)
            if '"id":"' in users:
                uid = users.split('"id":"', 1)[1].split('"', 1)[0]
            else:
                ctx.fail("Failed to parse user ID from response")
        elif service_account_user_client_id != None:
            # Get client ID first
            curl_cmd = (
                ["curl", "-s", "-X", "GET"]
                + (["-H", "Authorization: Bearer " + token] if token else [])
                + (["-u", auth_username + ":" + auth_password] if auth_username and auth_password and not token else [])
                + ["--connect-timeout", str(connection_timeout), "--user-agent", http_agent]
                + [auth_keycloak_url + "/admin/realms/" + realm + "/clients?clientId=" + service_account_user_client_id]
            )
            res = ctx.run(curl_cmd, mutates=False)
            if res.rc != 0:
                ctx.fail("Failed to fetch client: " + res.stderr)
            client_data = res.stdout.strip()
            if client_data == "[]" or client_data == "":
                ctx.fail("Client not found: " + service_account_user_client_id)
            if '"id":"' in client_data:
                client_id_found = client_data.split('"id":"', 1)[1].split('"', 1)[0]
            else:
                ctx.fail("Failed to parse client ID")
            # Fetch service account user
            curl_cmd = (
                ["curl", "-s", "-X", "GET"]
                + (["-H", "Authorization: Bearer " + token] if token else [])
                + (["-u", auth_username + ":" + auth_password] if auth_username and auth_password and not token else [])
                + ["--connect-timeout", str(connection_timeout), "--user-agent", http_agent]
                + [auth_keycloak_url + "/admin/realms/" + realm + "/clients/" + client_id_found + "/service-account-user"]
            )
            res = ctx.run(curl_cmd, mutates=False)
            if res.rc != 0:
                ctx.fail("Failed to fetch service account user: " + res.stderr)
            sa_data = res.stdout.strip()
            if sa_data == "" or '"id"' not in sa_data:
                ctx.fail("Service account user not found for client: " + service_account_user_client_id)
            if '"id":"' in sa_data:
                uid = sa_data.split('"id":"', 1)[1].split('"', 1)[0]
            else:
                ctx.fail("Failed to parse service account user ID")

    # Get client ID if missing
    if cid == None and client_id != None:
        curl_cmd = (
            ["curl", "-s", "-X", "GET"]
            + (["-H", "Authorization: Bearer " + token] if token else [])
            + (["-u", auth_username + ":" + auth_password] if auth_username and auth_password and not token else [])
            + ["--connect-timeout", str(connection_timeout), "--user-agent", http_agent]
            + [auth_keycloak_url + "/admin/realms/" + realm + "/clients?clientId=" + client_id]
        )
        res = ctx.run(curl_cmd, mutates=False)
        if res.rc != 0:
            ctx.fail("Failed to fetch client: " + res.stderr)
        client_data = res.stdout.strip()
        if client_data == "[]" or client_data == "":
            ctx.fail("Client not found: " + client_id)
        if '"id":"' in client_data:
            cid = client_data.split('"id":"', 1)[1].split('"', 1)[0]

    # Roles validation
    if roles == None or len(roles) == 0:
        return {"changed": False, "msg": "Nothing to do (no roles specified)."}

    # Resolve role IDs/names
    for role in roles:
        name = role.get("name")
        rid = role.get("id")
        if name == None and rid == None:
            ctx.fail("Each role must specify at least name or id.")

        # Resolve missing role ID
        if rid == None:
            url_part = "realm/roles" if cid == None else "clients/" + cid + "/roles"
            curl_cmd = (
                ["curl", "-s", "-X", "GET"]
                + (["-H", "Authorization: Bearer " + token] if token else [])
                + (["-u", auth_username + ":" + auth_password] if auth_username and auth_password and not token else [])
                + ["--connect-timeout", str(connection_timeout), "--user-agent", http_agent]
                + [auth_keycloak_url + "/admin/realms/" + realm + "/" + url_part + "?search=" + name]
            )
            res = ctx.run(curl_cmd, mutates=False)
            if res.rc != 0:
                ctx.fail("Failed to fetch role: " + res.stderr)
            role_data = res.stdout.strip()
            if role_data == "[]" or role_data == "":
                ctx.fail("Role not found: " + name)
            if '"id":"' in role_data:
                rid = role_data.split('"id":"', 1)[1].split('"', 1)[0]
                role["id"] = rid
            else:
                ctx.fail("Failed to parse role ID")

        # Resolve missing role name
        if name == None:
            url_part = "realm/roles" if cid == None else "clients/" + cid + "/roles"
            curl_cmd = (
                ["curl", "-s", "-X", "GET"]
                + (["-H", "Authorization: Bearer " + token] if token else [])
                + (["-u", auth_username + ":" + auth_password] if auth_username and auth_password and not token else [])
                + ["--connect-timeout", str(connection_timeout), "--user-agent", http_agent]
                + [auth_keycloak_url + "/admin/realms/" + realm + "/" + url_part + "/" + rid]
            )
            res = ctx.run(curl_cmd, mutates=False)
            if res.rc != 0:
                ctx.fail("Failed to fetch role: " + res.stderr)
            role_json = res.stdout.strip()
            if '"name":"' in role_json:
                name_val = role_json.split('"name":"', 1)[1].split('"', 1)[0]
                role["name"] = name_val
            else:
                ctx.fail("Failed to parse role name")

    # Get current assigned roles
    url_part = "users/" + uid + "/role-mappings/realm" if cid == None else "users/" + uid + "/role-mappings/clients/" + cid
    curl_cmd = (
        ["curl", "-s", "-X", "GET"]
        + (["-H", "Authorization: Bearer " + token] if token else [])
        + (["-u", auth_username + ":" + auth_password] if auth_username and auth_password and not token else [])
        + ["--connect-timeout", str(connection_timeout), "--user-agent", http_agent]
        + [auth_keycloak_url + "/admin/realms/" + realm + "/" + url_part + "/composite"]
    )
    res = ctx.run(curl_cmd, mutates=False)
    if res.rc != 0:
        ctx.fail("Failed to fetch existing rolemappings: " + res.stderr)
    existing_roles = res.stdout.strip()
    # Extract assigned role IDs into a list (simple parsing)
    assigned_ids = []
    temp = existing_roles
    while '"id":"' in temp:
        temp = temp.split('"id":"', 1)[1]
        rid = temp.split('"', 1)[0]
        if rid != "":
            assigned_ids.append(rid)

    # Determine actions: roles to add (present) or remove (absent)
    desired_ids = [r["id"] for r in roles]
    if state == "present":
        to_change = [r for r in roles if r["id"] not in assigned_ids]
    else:
        to_change = [r for r in roles if r["id"] in assigned_ids]

    # Prepare return dict
    result = {
        "changed": len(to_change) > 0,
        "msg": "",
        "existing": existing_roles,
        "proposed": roles,
    }

    # No changes needed?
    if len(to_change) == 0:
        result["msg"] = "Nothing to do, roles already mapped."
        result["end_state"] = existing_roles
        return result

    # In check_mode, we just return the prediction
    if ctx.check_mode:
        result["msg"] = ("Roles assigned to" if state == "present" else "Roles removed from") + " user."
        return result

    # Perform mutation: POST for assign, DELETE for remove
    if len(to_change) > 0:
        payload = "["
        for idx, r in enumerate(to_change):
            payload += '{"id":"' + r["id"] + '","name":"' + r["name"] + '"}'
            if idx < len(to_change) - 1:
                payload += ","
        payload += "]"
        url_part = "users/" + uid + "/role-mappings/realm" if cid == None else "users/" + uid + "/role-mappings/clients/" + cid
        curl_cmd = (
            ["curl", "-s", "-X", "POST" if state == "present" else "DELETE"]
            + (["-H", "Authorization: Bearer " + token] if token else [])
            + (["-u", auth_username + ":" + auth_password] if auth_username and auth_password and not token else [])
            + ["--connect-timeout", str(connection_timeout), "--user-agent", http_agent]
            + ["-H", "Content-Type: application/json"]
            + ["-d", payload]
            + [auth_keycloak_url + "/admin/realms/" + realm + "/" + url_part]
        )
        res = ctx.run(curl_cmd, mutates=True)
        if res.rc != 0:
            ctx.fail(("Assigning" if state == "present" else "Removing") + " roles failed: " + res.stderr)

        # Fetch updated mapping for end_state
        curl_cmd = (
            ["curl", "-s", "-X", "GET"]
            + (["-H", "Authorization: Bearer " + token] if token else [])
            + (["-u", auth_username + ":" + auth_password] if auth_username and auth_password and not token else [])
            + ["--connect-timeout", str(connection_timeout), "--user-agent", http_agent]
            + [auth_keycloak_url + "/admin/realms/" + realm + "/" + url_part + "/composite"]
        )
        res2 = ctx.run(curl_cmd, mutates=False)
        if res2.rc != 0:
            result["end_state"] = ""
        else:
            result["end_state"] = res2.stdout.strip()
        result["msg"] = ("Roles assigned to" if state == "present" else "Roles removed from") + " user."
        return result
    else:
        result["msg"] = "Nothing to do."
        result["end_state"] = existing_roles
        return result
