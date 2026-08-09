def main(ctx, params):
    # Extract and validate required parameters
    auth_keycloak_url = params["auth_keycloak_url"]
    realm = params.get("realm", "master")
    group_name = params.get("group_name")
    gid = params.get("gid")
    roles = params.get("roles")
    parents = params.get("parents")
    state = params.get("state", "present")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")
    auth_client_id = params.get("auth_client_id", "admin-cli")

    # Check required group identification
    if gid == None and group_name == None:
        fail("Either 'group_name' or 'gid' must be specified.")

    # Handle authentication: prefer token, else build from credentials
    token = params.get("token")
    if token == None:
        auth_realm = params.get("auth_realm")
        auth_username = params.get("auth_username")
        auth_password = params.get("auth_password")
        auth_client_secret = params.get("auth_client_secret")

        if auth_realm == None or auth_username == None or auth_password == None:
            fail("Authentication: either 'token' must be provided, or 'auth_realm', 'auth_username', and 'auth_password'.")

        # Build auth payload (simplified for Starlark)
        auth_data = "grant_type=password&client_id=" + auth_client_id
        if auth_client_secret:
            auth_data += "&client_secret=" + auth_client_secret
        auth_data += "&username=" + auth_username + "&password=" + auth_password
        if auth_realm:
            auth_data += "&realm=" + auth_realm

        auth_res = ctx.run(
            ["curl", "-s", "-X", "POST", "-d", auth_data, auth_keycloak_url + "/realms/" + auth_realm + "/protocol/openid-connect/token"],
            mutates=False
        )
        if auth_res.rc != 0:
            fail("Failed to obtain access token: " + auth_res.stderr)

        # Manual JSON parsing (Starlark-safe)
        token = ""
        parts_list = auth_res.stdout.split(",")
        for part in parts_list:
            if '"access_token"' in part:
                subparts = part.split(":")
                for sub in subparts:
                    cleaned = sub.strip().strip('"')
                    if cleaned != "access_token" and cleaned != "":
                        token = cleaned
                        break
            if token != "":
                break
        if token == "":
            fail("Failed to parse access_token from response")

    # Helper: HTTP headers
    def headers():
        return ["-H", "Authorization: Bearer " + token, "-H", "User-Agent: " + http_agent, "-H", "Content-Type: application/json"]

    # Helper: get group by name (with parent chain resolution)
    def get_group_by_name(name, realm, parents_list):
        path = "/realms/" + realm + "/groups"
        if parents_list != None and len(parents_list) > 0:
            for p in parents_list:
                pid = p.get("id")
                pname = p.get("name")
                if pid != None:
                    path = path + "/" + pid + "/children"
                else:
                    res = ctx.run(["curl", "-s"] + headers() + [auth_keycloak_url + path])
                    if res.rc != 0:
                        fail("Failed to list groups at " + path + ": " + res.stderr)
                    found = False
                    for line in res.stdout.split("\n"):
                        if '"name"' in line and pname in line:
                            for sub in line.split(","):
                                if '"id"' in sub:
                                    for subsub in sub.split(":"):
                                        v = subsub.strip().strip('"')
                                        if v != "id" and v != "":
                                            path = path + "/" + v + "/children"
                                            found = True
                                            break
                                if found:
                                    break
                        if found:
                            break
                    if not found:
                        return None
        res = ctx.run(["curl", "-s"] + headers() + [auth_keycloak_url + path])
        if res.rc != 0:
            fail("Failed to list groups: " + res.stderr)
        for line in res.stdout.split("\n"):
            if '"name"' in line and name in line:
                for sub in line.split(","):
                    if '"id"' in sub:
                        for subsub in sub.split(":"):
                            v = subsub.strip().strip('"')
                            if v != "id" and v != "":
                                return {"id": v}
        return None

    # Helper: get group by ID
    def get_group_by_id(gid_val, realm):
        res = ctx.run(["curl", "-s"] + headers() + [auth_keycloak_url + "/realms/" + realm + "/groups/" + gid_val])
        if res.rc != 0:
            return None
        return {"id": gid_val}

    # Fetch group if only name provided
    if gid == None:
        group_rep = get_group_by_name(group_name, realm, parents)
        if group_rep == None:
            fail("Could not fetch group '%s'." % group_name)
        gid = group_rep["id"]
    else:
        group_rep = get_group_by_id(gid, realm)
        if group_rep == None:
            fail("Could not fetch group by ID '%s'." % gid)

    # If no roles provided, exit early
    if roles == None:
        return {"changed": False, "msg": "Nothing to do (no roles specified)."}

    # Fetch all realm roles once to resolve missing names/ids
    all_realm_roles = {}
    res = ctx.run(["curl", "-s"] + headers() + [auth_keycloak_url + "/realms/" + realm + "/roles"])
    if res.rc != 0:
        fail("Failed to list realm roles: " + res.stderr)
    for line in res.stdout.split("\n"):
        if '"name"' in line:
            name = ""
            role_id = ""
            for sub in line.split(","):
                if '"name"' in sub:
                    subparts = sub.split(":")
                    name = subparts[1].strip().strip('"') if len(subparts) > 1 else ""
                elif '"id"' in sub:
                    subparts = sub.split(":")
                    role_id = subparts[1].strip().strip('"') if len(subparts) > 1 else ""
            if name != "" and role_id != "":
                all_realm_roles[name] = role_id
                all_realm_roles[role_id] = name

    # Validate and resolve each role
    for role in roles:
        name = role.get("name")
        rid = role.get("id")
        if name == None and rid == None:
            fail("Each role must specify at least 'name' or 'id'.")
        if rid == None:
            if all_realm_roles.get(name) == None:
                fail("Could not fetch realm role '%s' by name." % name)
            role["id"] = all_realm_roles.get(name)
        if name == None:
            if all_realm_roles.get(rid) == None:
                fail("Could not fetch realm role by ID '%s'." % rid)
            role["name"] = all_realm_roles.get(rid)

    # Fetch current role mappings for the group
    res = ctx.run(["curl", "-s"] + headers() + [auth_keycloak_url + "/realms/" + realm + "/groups/" + gid + "/role-mappings/realm"])
    if res.rc != 0:
        fail("Failed to fetch existing role mappings: " + res.stderr)
    existing_roles = []
    for line in res.stdout.split("\n"):
        if '"name"' in line:
            for sub in line.split(","):
                if '"name"' in sub:
                    subparts = sub.split(":")
                    n = subparts[1].strip().strip('"') if len(subparts) > 1 else ""
                    if n != "":
                        existing_roles.append(n)
                        break

    # Determine proposed changes
    proposed = list(existing_roles)
    update_roles = []

    for role in roles:
        name = role["name"]
        if state == "present":
            if existing_roles.count(name) == 0:
                update_roles.append(role)
                proposed.append(name)
        else:
            if existing_roles.count(name) > 0:
                update_roles.append(role)
                if name in proposed:
                    proposed.remove(name)

    # Build return state
    result = {
        "changed": len(update_roles) > 0,
        "msg": "",
        "existing": existing_roles,
        "proposed": proposed,
        "end_state": []
    }

    if len(update_roles) == 0:
        result["msg"] = "Nothing to do, roles are " + ("mapped" if state == "present" else "not mapped") + " with group '%s'." % group_name
        result["changed"] = False
        return result

    if ctx.check_mode:
        result["msg"] = "Would update role mappings."
        return result

    # Apply changes: build payload
    payload = "["
    for i, role in enumerate(update_roles):
        if i > 0:
            payload += ","
        payload += '{"id": "' + role["id"] + '", "name": "' + role["name"] + '"}'
    payload += "]"

    # Perform the operation
    if state == "present":
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-d", payload] + headers() +
            [auth_keycloak_url + "/realms/" + realm + "/groups/" + gid + "/role-mappings/realm"],
            mutates=True
        )
        if res.rc != 0:
            fail("Failed to assign roles: " + res.stderr)
        result["msg"] = "Realm roles " + str(update_roles) + " assigned to group ID " + gid + "."
    else:
        for role in update_roles:
            rid = role["id"]
            res = ctx.run(
                ["curl", "-s", "-X", "DELETE"] + headers() +
                [auth_keycloak_url + "/realms/" + realm + "/groups/" + gid + "/role-mappings/realm/representations/" + rid],
                mutates=True
            )
            if res.rc != 0:
                fail("Failed to remove role " + rid + ": " + res.stderr)
        result["msg"] = "Realm roles " + str(update_roles) + " removed from group ID " + gid + "."

    # Refresh end_state
    res = ctx.run(["curl", "-s"] + headers() + [auth_keycloak_url + "/realms/" + realm + "/groups/" + gid + "/role-mappings/realm"])
    if res.rc != 0:
        fail("Failed to refresh role mappings for end_state: " + res.stderr)
    end_roles = []
    for line in res.stdout.split("\n"):
        if '"name"' in line:
            for sub in line.split(","):
                if '"name"' in sub:
                    subparts = sub.split(":")
                    n = subparts[1].strip().strip('"') if len(subparts) > 1 else ""
                    if n != "":
                        end_roles.append(n)
                        break
    result["end_state"] = end_roles

    return result
