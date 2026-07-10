def main(ctx, params):
    # Required auth fields
    auth_url = params.get("auth_keycloak_url")
    if auth_url == None:
        fail("auth_keycloak_url is required")
    auth_realm = params.get("auth_realm", "master")
    auth_client_id = params.get("auth_client_id", "admin-cli")
    token = params.get("token")
    username = params.get("auth_username")
    password = params.get("auth_password")
    client_secret = params.get("auth_client_secret")

    # Other params
    realm = params.get("realm", "master")
    name = params.get("name")
    gid = params.get("id")
    state = params.get("state", "present")
    attributes = params.get("attributes")
    parents = params.get("parents")

    if state == "absent" and name == None and gid == None:
        fail("id or name is required when state is absent")

    if state == "present" and name == None:
        fail("name is required when state is present")

    # Helper: build URL path
    def api_url(path):
        return auth_url.rstrip("/") + "/admin/realms/" + realm + path

    # Helper: get token
    def get_token():
        if token != None:
            return token
        if username == None or password == None:
            fail("auth_username and auth_password or token is required for authentication")
        token_url = api_url("/realms/master/protocol/openid-connect/token")
        body = "grant_type=password&client_id=" + auth_client_id + "&username=" + username + "&password=" + password
        if client_secret != None:
            body = body + "&client_secret=" + client_secret
        res = ctx.run(
            [
                "curl",
                "-sS",
                "-X", "POST",
                "-H", "Content-Type: application/x-www-form-urlencoded",
                "-d", body,
                token_url,
            ],
            mutates=False,
        )
        if res.rc != 0:
            fail("failed to obtain token: " + res.stderr)
        raw = res.stdout
        token_start = raw.find('"access_token":"')
        if token_start == -1:
            fail("token parsing failed: access_token not found in response")
        token_start += len('"access_token":"')
        token_end = raw.find('"', token_start)
        if token_end == -1:
            fail("token parsing failed: invalid token format")
        return raw[token_start:token_end]

    token_val = get_token()
    headers = ["-H", "Authorization: Bearer " + token_val, "-H", "Accept: application/json"]

    # Helper: POST/PUT/DELETE
    def call_api(method, path, data_json=None):
        url = api_url(path)
        cmd = ["curl", "-sS", "-X", method] + headers
        if data_json != None:
            cmd.extend(["-H", "Content-Type: application/json", "-d", data_json])
        cmd.append(url)
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail(method + " " + url + " failed: " + res.stderr)
        return res.stdout

    # Minimal JSON parser for Keycloak responses
    def parse_json(raw):
        raw = raw.strip()
        if raw == "" or raw == "null":
            return None
        if raw == "true":
            return True
        if raw == "false":
            return False
        if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
            return raw[1:-1]
        if raw.startswith("[") and raw.endswith("]"):
            inner = raw[1:-1].strip()
            if inner == "":
                return []
            items = []
            depth = 0
            current = ""
            in_string = False
            for i in range(len(inner)):
                ch = inner[i]
                if ch == '"' and (i == 0 or inner[i-1] != '\\'):
                    in_string = not in_string
                if not in_string:
                    if ch in "[{":
                        depth += 1
                    elif ch in "]}":
                        depth -= 1
                if not in_string and ch == "," and depth == 0:
                    items.append(parse_json(current.strip()))
                    current = ""
                else:
                    current += ch
            if current.strip() != "":
                items.append(parse_json(current.strip()))
            return items
        if raw.startswith("{") and raw.endswith("}"):
            inner = raw[1:-1].strip()
            if inner == "":
                return {}
            result = {}
            depth = 0
            current = ""
            in_string = False
            for i in range(len(inner)):
                ch = inner[i]
                if ch == '"' and (i == 0 or inner[i-1] != '\\'):
                    in_string = not in_string
                if not in_string:
                    if ch in "[{":
                        depth += 1
                    elif ch in "]}":
                        depth -= 1
                if not in_string and ch == "," and depth == 0:
                    idx = current.find(":")
                    if idx > 0:
                        k = current[0:idx].strip()
                        v = current[idx+1:].strip()
                        if k.startswith('"') and k.endswith('"') and len(k) >= 2:
                            k = k[1:-1]
                        result[k] = parse_json(v)
                    current = ""
                else:
                    current += ch
            if current.strip() != "":
                idx = current.find(":")
                if idx > 0:
                    k = current[0:idx].strip()
                    v = current[idx+1:].strip()
                    if k.startswith('"') and k.endswith('"') and len(k) >= 2:
                        k = k[1:-1]
                    result[k] = parse_json(v)
            return result
        fail("unparseable JSON: " + raw)

    # Get group by ID
    def get_group_by_id(gid_val):
        raw = call_api("GET", "/groups/" + gid_val)
        return parse_json(raw)

    # Get group by name (simple search)
    def get_group_by_name_simple(name_val):
        raw = call_api("GET", "/groups?search=" + name_val + "&max=1")
        if raw == None or raw.strip() == "":
            return None
        groups = parse_json(raw)
        if groups == None or type(groups) == "NoneType":
            return None
        if type(groups) != "list":
            return None
        for g in groups:
            if type(g) == "dict" and g.get("name") == name_val:
                return g
        return None

    # Get group ID by name
    def get_group_id_by_name(name_val):
        g = get_group_by_name_simple(name_val)
        if g == None:
            return None
        return g.get("id")

    # Get group by name with parent chain
    def get_group_by_name_with_parents(name_val, parents_list):
        parent_ids = []
        if parents_list != None:
            for p in parents_list:
                pid = p.get("id")
                if pid == None:
                    pname = p.get("name")
                    if pname == None:
                        fail("each parent must have id or name")
                    pid = get_group_id_by_name(pname)
                    if pid == None:
                        fail("parent group not found: " + pname)
                parent_ids.append(pid)

        current_id = None
        for i in range(len(parent_ids)):
            pid = parent_ids[i]
            if current_id == None:
                raw = call_api("GET", "/groups?search=" + pid)
                children = parse_json(raw)
                if children == None or type(children) != "list":
                    return None
                current_id = None
                for g in children:
                    if type(g) == "dict":
                        if g.get("name") == pid or g.get("id") == pid:
                            current_id = g.get("id")
                            break
            else:
                raw = call_api("GET", "/groups/" + current_id + "/children?search=" + pid)
                children = parse_json(raw)
                if children == None or type(children) != "list":
                    return None
                current_id = None
                for g in children:
                    if type(g) == "dict":
                        if g.get("name") == pid or g.get("id") == pid:
                            current_id = g.get("id")
                            break
            if current_id == None:
                return None

        if current_id != None:
            return get_group_by_id(current_id)
        return get_group_by_name_simple(name_val)

    # Fetch current group
    before_group = None
    if gid != None:
        before_group = get_group_by_id(gid)
    else:
        before_group = get_group_by_name_with_parents(name, parents)

    # Normalize attributes (convert single values to list)
    if attributes != None:
        new_attrs = {}
        for key in attributes.keys():
            val = attributes.get(key)
            if type(val) == "string":
                new_attrs[key] = [val]
            else:
                new_attrs[key] = val
        attributes = new_attrs

    # Build desired group payload
    desired_group = {}
    if gid != None:
        desired_group["id"] = gid
    if name != None:
        desired_group["name"] = name
    if attributes != None:
        desired_group["attributes"] = attributes

    # Detect changes
    changed = False
    if before_group != None:
        for k in desired_group.keys():
            if before_group.get(k) != desired_group.get(k):
                changed = True
                break
        if not changed:
            for k in before_group.keys():
                if k != "id" and desired_group.get(k) != before_group.get(k):
                    changed = True
                    break

    # Action
    if state == "absent":
        if before_group == None:
            return {"changed": False, "msg": "Group does not exist; doing nothing."}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete group " + (name or gid)}
        call_api("DELETE", "/groups/" + before_group.get("id"))
        return {"changed": True, "msg": "Group " + (name or str(gid)) + " has been deleted", "data": {"end_state": {}}}

    # state == "present"
    if before_group != None and not changed:
        return {"changed": False, "msg": "Group " + name + " is already up-to-date", "data": {"end_state": before_group}}

    if ctx.check_mode:
        return {"changed": True, "msg": "would " + ("update" if before_group != None else "create") + " group " + name}

    if before_group == None:
        if parents != None and len(parents) > 0:
            pid = parents[0].get("id")
            if pid == None:
                pname = parents[0].get("name")
                pid = get_group_id_by_name(pname)
                if pid == None:
                    fail("parent group not found: " + pname)
            call_api("POST", "/groups/" + pid + "/children", str(desired_group))
        else:
            call_api("POST", "/groups", str(desired_group))
        after_group = get_group_by_name_with_parents(name, parents)
        if after_group == None:
            fail("group created but could not be retrieved")
        return {"changed": True, "msg": "Group " + name + " has been created with ID " + str(after_group.get("id")), "data": {"end_state": after_group}}
    else:
        gid_val = before_group.get("id")
        call_api("PUT", "/groups/" + gid_val, str(desired_group))
        after_group = get_group_by_id(gid_val)
        return {"changed": True, "msg": "Group " + name + " has been updated", "data": {"end_state": after_group}}
