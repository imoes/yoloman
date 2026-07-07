def main(ctx, params):
    # Extract parameters with defaults
    realm = params.get("realm", "master")
    state = params.get("state", "present")
    group_name = params.get("group_name")
    gid = params.get("gid")
    client_id = params.get("client_id")
    cid = params.get("cid")
    roles = params.get("roles", [])
    parents = params.get("parents", [])
    url = params["auth_keycloak_url"]
    auth_client_id = params.get("auth_client_id", "admin-cli")
    validate_certs = params.get("validate_certs", True)
    timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Parameter validation
    if not client_id and not cid:
        fail("Either 'client_id' or 'cid' must be specified.")
    if not group_name and not gid:
        fail("Either 'group_name' or 'gid' must be specified.")

    # Helper: construct auth header from token or basic auth
    def get_auth_header():
        token = params.get("token")
        if token:
            return "Bearer " + token
        username = params.get("auth_username")
        password = params.get("auth_password")
        auth_realm = params.get("auth_realm", "master")
        auth_client_secret = params.get("auth_client_secret")
        if not (username and password):
            fail("Authentication requires 'token' or 'auth_username' + 'auth_password'.")
        # Obtain token via password grant
        payload = (
            "grant_type=password&client_id=" + auth_client_id +
            "&username=" + username +
            "&password=" + password +
            ("&client_secret=" + auth_client_secret if auth_client_secret else "")
        )
        res = ctx.run(
            ["curl", "-s", "-X", "POST", url + "/realms/" + auth_realm + "/protocol/openid-connect/token",
             "-H", "Content-Type: application/x-www-form-urlencoded",
             "-d", payload,
             "-k" if not validate_certs else "",
             "--connect-timeout", str(timeout),
             "-A", http_agent],
            mutates=False
        )
        if res.rc != 0:
            fail("Token request failed: " + res.stderr)
        data = res.stdout
        # Parse JSON manually (no json module) — simple extraction of access_token
        token_start = data.find('"access_token":"')
        if token_start == -1:
            fail("Could not extract access_token from response.")
        token_start += len('"access_token":"')
        token_end = data.find('"', token_start)
        token = data[token_start:token_end]
        return "Bearer " + token

    auth_header = get_auth_header()

    # Helper: perform GET request
    def get(path, ok_codes=[0, 200, 204]):
        res = ctx.run(
            ["curl", "-s", "-X", "GET", url + path,
             "-H", "Authorization: " + auth_header,
             "-k" if not validate_certs else "",
             "--connect-timeout", str(timeout),
             "-A", http_agent],
            mutates=False,
            ok_codes=ok_codes
        )
        if res.rc not in ok_codes:
            fail("GET " + path + " failed: " + res.stderr)
        return res.stdout

    # Helper: perform POST request
    def post(path, body, ok_codes=[0, 200, 201, 204]):
        res = ctx.run(
            ["curl", "-s", "-X", "POST", url + path,
             "-H", "Authorization: " + auth_header,
             "-H", "Content-Type: application/json",
             "-d", body,
             "-k" if not validate_certs else "",
             "--connect-timeout", str(timeout),
             "-A", http_agent],
            mutates=True,
            ok_codes=ok_codes
        )
        if res.rc not in ok_codes:
            fail("POST " + path + " failed: " + res.stderr)
        return res.stdout

    # Helper: perform DELETE request
    def delete(path, ok_codes=[0, 200, 204]):
        res = ctx.run(
            ["curl", "-s", "-X", "DELETE", url + path,
             "-H", "Authorization: " + auth_header,
             "-k" if not validate_certs else "",
             "--connect-timeout", str(timeout),
             "-A", http_agent],
            mutates=True,
            ok_codes=ok_codes
        )
        if res.rc not in ok_codes:
            fail("DELETE " + path + " failed: " + res.stderr)
        return res.stdout

    # Helper: fetch group ID by name (with parent chain)
    def get_group_id_by_name(name, parents_list):
        if len(parents_list) == 0:
            # Top-level group lookup
            res = get("/admin/realms/" + realm + "/groups?search=" + name)
            # Simple JSON parsing: find the group with matching name
            for line in res.splitlines():
                if '"name"' in line and name in line:
                    start = line.find('"id":"')
                    if start != -1:
                        start += len('"id":"')
                        end = line.find('"', start)
                        return line[start:end]
        else:
            # Traverse parent chain
            parent_path = ""
            for p in parents_list:
                pid = p.get("id")
                pname = p.get("name")
                if pid:
                    # Use ID directly
                    parent_path = pid
                    if pname == None:
                        # No further lookups needed; this group exists
                        break
                else:
                    # Must search by name under current parent
                    if len(parent_path) == 0:
                        search_path = "/admin/realms/" + realm + "/groups?search=" + pname
                    else:
                        search_path = parent_path + "/children?search=" + pname
                    data = get(search_path)
                    # Parse: find group with matching name
                    found = False
                    for line in data.splitlines():
                        if '"name"' in line and pname in line:
                            start = line.find('"id":"')
                            if start != -1:
                                start += len('"id":"')
                                end = line.find('"', start)
                                pid = line[start:end]
                                parent_path = pid
                                found = True
                                break
                    if not found:
                        fail("Parent group '" + pname + "' not found.")
            # Finally, search for the target group under last parent
            if len(parent_path) > 0:
                data = get(parent_path + "/children?search=" + name)
            else:
                data = get("/admin/realms/" + realm + "/groups?search=" + name)
            for line in data.splitlines():
                if '"name"' in line and name in line:
                    start = line.find('"id":"')
                    if start != -1:
                        start += len('"id":"')
                        end = line.find('"', start)
                        return line[start:end]
        return None

    # Fetch group and client IDs if missing
    if not gid:
        gid = get_group_id_by_name(group_name, parents)
        if not gid:
            fail("Group '" + group_name + "' not found.")
    if not cid:
        # Fetch client ID by name
        data = get("/admin/realms/" + realm + "/clients?clientId=" + client_id)
        for line in data.splitlines():
            if '"clientId"' in line and client_id in line:
                start = line.find('"id":"')
                if start != -1:
                    start += len('"id":"')
                    end = line.find('"', start)
                    cid = line[start:end]
                    break
        if not cid:
            fail("Client '" + client_id + "' not found.")

    # Ensure roles is not empty
    if len(roles) == 0:
        return {"changed": False, "msg": "Nothing to do (no roles specified)."}

    # Validate roles parameters
    for role in roles:
        if not role.get("name") and not role.get("id"):
            fail("Each role must specify either 'name' or 'id'.")

    # Fetch available and assigned role IDs for the client-group mapping
    available_roles_data = get("/admin/realms/" + realm + "/groups/" + gid + "/role-mappings/clients/" + cid + "/available")
    assigned_roles_data = get("/admin/realms/" + realm + "/groups/" + gid + "/role-mappings/clients/" + cid + "/composite")

    # Parse available and assigned roles into lists of {id, name}
    available_roles = []
    for line in available_roles_data.splitlines():
        if '"name"' in line:
            name = ""
            id_ = ""
            # Extract name
            nstart = line.find('"name":"')
            if nstart != -1:
                nstart += len('"name":"')
                nend = line.find('"', nstart)
                name = line[nstart:nend]
            # Extract id
            istart = line.find('"id":"')
            if istart != -1:
                istart += len('"id":"')
                iend = line.find('"', istart)
                id_ = line[istart:iend]
            if len(name) > 0:
                available_roles.append({"name": name, "id": id_})

    assigned_roles = []
    for line in assigned_roles_data.splitlines():
        if '"name"' in line:
            name = ""
            id_ = ""
            nstart = line.find('"name":"')
            if nstart != -1:
                nstart += len('"name":"')
                nend = line.find('"', nstart)
                name = line[nstart:nend]
            istart = line.find('"id":"')
            if istart != -1:
                istart += len('"id":"')
                iend = line.find('"', istart)
                id_ = line[istart:iend]
            if len(name) > 0:
                assigned_roles.append({"name": name, "id": id_})

    # Enrich role list with missing ids/names
    for role in roles:
        if not role.get("id") and role.get("name"):
            # Look up role ID by name in available roles
            for r in available_roles:
                if r["name"] == role["name"]:
                    role["id"] = r["id"]
                    break
            if not role.get("id"):
                fail("Role '" + role["name"] + "' not found in available roles.")
        elif not role.get("name") and role.get("id"):
            # Look up role name by ID
            for r in available_roles:
                if r["id"] == role["id"]:
                    role["name"] = r["name"]
                    break
            if not role.get("name"):
                fail("Role ID '" + role["id"] + "' not found in available roles.")

    # Compute desired changes
    to_add = []
    to_remove = []
    for role in roles:
        # Check if assigned
        assigned = False
        for r in assigned_roles:
            if r["id"] == role["id"]:
                assigned = True
                break
        if state == "present" and not assigned:
            to_add.append({"id": role["id"], "name": role["name"]})
        elif state == "absent" and assigned:
            to_remove.append({"id": role["id"], "name": role["name"]})

    # Prepare result data (diff)
    proposed = []
    for r in assigned_roles:
        proposed.append({"id": r["id"], "name": r["name"]})
    if state == "present":
        for r in to_add:
            found = False
            for pr in proposed:
                if pr["id"] == r["id"]:
                    found = True
                    break
            if not found:
                proposed.append(r)
    else:
        for r in to_remove:
            new_proposed = []
            for pr in proposed:
                if not (pr["id"] == r["id"] and pr["name"] == r["name"]):
                    new_proposed.append(pr)
            proposed = new_proposed

    # Idempotency: no change needed?
    if len(to_add) == 0 and len(to_remove) == 0:
        msg = "Nothing to do, roles are " + ("mapped" if state == "present" else "not mapped") + " with group '" + group_name + "'."
        return {"changed": False, "msg": msg, "proposed": proposed, "existing": assigned_roles, "end_state": proposed}

    # In check_mode, report what would change
    if ctx.check_mode:
        return {"changed": True, "msg": "would update role mapping", "diff": {"before": assigned_roles, "after": proposed},
                "proposed": proposed, "existing": assigned_roles, "end_state": proposed}

    # Apply changes
    if len(to_add) > 0:
        # Convert to JSON manually
        body = "["
        for i in range(len(to_add)):
            if i > 0:
                body = body + ","
            body = body + '{"id":"' + to_add[i]["id"] + '","name":"' + to_add[i]["name"] + '"}'
        body = body + "]"
        post("/admin/realms/" + realm + "/groups/" + gid + "/role-mappings/clients/" + cid, body, ok_codes=[0, 200, 204])

    if len(to_remove) > 0:
        for role in to_remove:
            delete("/admin/realms/" + realm + "/groups/" + gid + "/role-mappings/clients/" + cid + "/roles?id=" + role["id"], ok_codes=[0, 200, 204])

    # Fetch final state
    final_data = get("/admin/realms/" + realm + "/groups/" + gid + "/role-mappings/clients/" + cid + "/composite")
    final_roles = []
    for line in final_data.splitlines():
        if '"name"' in line:
            name = ""
            id_ = ""
            nstart = line.find('"name":"')
            if nstart != -1:
                nstart += len('"name":"')
                nend = line.find('"', nstart)
                name = line[nstart:nend]
            istart = line.find('"id":"')
            if istart != -1:
                istart += len('"id":"')
                iend = line.find('"', istart)
                id_ = line[istart:iend]
            if len(name) > 0:
                final_roles.append({"name": name, "id": id_})

    msg = ("Roles added to" if len(to_add) > 0 else "Roles removed from") + " group '" + group_name + "'."
    return {"changed": True, "msg": msg, "diff": {"before": assigned_roles, "after": proposed},
            "proposed": proposed, "existing": assigned_roles, "end_state": final_roles}
