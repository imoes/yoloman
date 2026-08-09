def main(ctx, params):
    # Required parameters
    userid = params["userid"]
    state = params.get("state", "present")

    # Optional parameters
    name = params.get("name")
    password = params.get("password")
    group = params.get("group")
    email = params.get("email")
    update_password = params.get("update_password", "always")

    # Handle manageiq_connection with environment fallbacks
    conn = params.get("manageiq_connection", {})
    url = conn.get("url")
    username = conn.get("username")
    password_arg = conn.get("password")
    token = conn.get("token")
    ca_cert = conn.get("ca_cert") or conn.get("ca_bundle_path")
    validate_certs = conn.get("validate_certs", True)
    if validate_certs == None:
        validate_certs = True

    # Get connection info with environment fallbacks
    if url == None:
        url = ctx.facts().get("env", {}).get("MIQ_URL")
    if username == None and password_arg == None and token == None:
        username = ctx.facts().get("env", {}).get("MIQ_USERNAME")
        password_arg = ctx.facts().get("env", {}).get("MIQ_PASSWORD")
        token = ctx.facts().get("env", {}).get("MIQ_TOKEN")
    if token == None and username == None and password_arg == None:
        fail("must provide either token or username+password in manageiq_connection")
    if url == None:
        fail("manageiq url is required (MIQ_URL environment variable or url in manageiq_connection)")

    # Build auth header
    auth_header = ""
    if token != None:
        auth_header = "Bearer " + token
    elif username != None and password_arg != None:
        auth_header = "Basic " + (username + ":" + password_arg).encode("utf-8").hex()
    else:
        fail("must provide either token or username+password")

    # Helper: query user directly
    def get_user(uid):
        curl_args = [
            "curl", "-sS", "-XGET",
            "-H", "Content-Type: application/json",
            "-H", "Authorization: " + auth_header,
            url + "/api/users?expand=resources&filter[]=" + uid
        ]
        res = ctx.run(curl_args, mutates=False)
        if res.rc != 0:
            fail("failed to query users: " + res.stderr)
        stdout = res.stdout
        # Find the resources array
        res_idx = stdout.find('"resources"')
        if res_idx == -1:
            return None
        bracket_start = stdout.find('[', res_idx)
        if bracket_start == -1:
            return None
        # Find first object in array
        obj_start = stdout.find('{', bracket_start)
        if obj_start == -1:
            return None
        # Find matching closing brace
        depth = 1
        i = obj_start + 1
        while i < len(stdout) and depth > 0:
            if stdout[i] == '{':
                depth += 1
            elif stdout[i] == '}':
                depth -= 1
            i += 1
        if depth != 0:
            return None
        obj_str = stdout[obj_start:i]
        # Extract id
        id_key = '"id"'
        id_idx = obj_str.find(id_key)
        if id_idx == -1:
            return None
        eq_idx = obj_str.find(':', id_idx)
        if eq_idx == -1:
            return None
        val_start = eq_idx + 1
        while val_start < len(obj_str) and obj_str[val_start] in (' ', '\t', '\n'):
            val_start += 1
        if val_start >= len(obj_str):
            return None
        if obj_str[val_start] == '"':
            val_start += 1
            val_end = obj_str.find('"', val_start)
            if val_end == -1:
                return None
            return {"id": obj_str[val_start:val_end]}
        else:
            val_end = val_start
            while val_end < len(obj_str) and obj_str[val_end].isdigit():
                val_end += 1
            if val_end == val_start:
                return None
            return {"id": obj_str[val_start:val_end]}
        return None

    user = get_user(userid)

    # Absent state
    if state == "absent":
        if user == None:
            return {"changed": False, "msg": "user %s does not exist in ManageIQ" % userid}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete user %s" % userid}
        curl_args = [
            "curl", "-sS", "-XPOST",
            "-H", "Content-Type: application/json",
            "-H", "Authorization: " + auth_header,
            "-d", '{"action":"delete"}',
            url + "/api/users/" + user["id"]
        ]
        res = ctx.run(curl_args, mutates=True)
        if res.rc != 0:
            fail("failed to delete user %s: %s" % (userid, res.stderr))
        return {"changed": True, "msg": "deleted user %s" % userid}

    # Present state
    if state == "present":
        # Required fields for creation
        if user == None:
            if name == None:
                fail("name is required when creating a user")
            if group == None:
                fail("group is required when creating a user")
            if password == None:
                fail("password is required when creating a user")

            # Resolve group ID
            group_id = None
            curl_args = [
                "curl", "-sS", "-XGET",
                "-H", "Content-Type: application/json",
                "-H", "Authorization: " + auth_header,
                url + "/api/groups?expand=resources&filter[]=" + group
            ]
            res = ctx.run(curl_args, mutates=False)
            if res.rc != 0:
                fail("failed to query groups: " + res.stderr)
            # naive extraction of group id
            stdout = res.stdout
            res_idx = stdout.find('"resources"')
            if res_idx != -1:
                bracket_start = stdout.find('[', res_idx)
                if bracket_start != -1:
                    obj_start = stdout.find('{', bracket_start)
                    if obj_start != -1:
                        depth = 1
                        i = obj_start + 1
                        while i < len(stdout) and depth > 0:
                            if stdout[i] == '{':
                                depth += 1
                            elif stdout[i] == '}':
                                depth -= 1
                            i += 1
                        if depth == 0:
                            obj_str = stdout[obj_start:i]
                            id_idx = obj_str.find('"id"')
                            if id_idx != -1:
                                eq_idx = obj_str.find(':', id_idx)
                                if eq_idx != -1:
                                    val_start = eq_idx + 1
                                    while val_start < len(obj_str) and obj_str[val_start] in (' ', '\t', '\n'):
                                        val_start += 1
                                    if val_start < len(obj_str) and obj_str[val_start].isdigit():
                                        val_end = val_start
                                        while val_end < len(obj_str) and obj_str[val_end].isdigit():
                                            val_end += 1
                                        group_id = int(obj_str[val_start:val_end])

            if group_id == None:
                fail("group %s not found" % group)

            # Create payload
            payload = '{"userid":"%s","name":"%s","password":"%s","group":{"id":%s}}' % (
                userid.replace('"', '\\"'), name.replace('"', '\\"'), password.replace('"', '\\"'), str(group_id))
            if email != None:
                payload = payload[:-1] + ',"email":"%s"}' % email.replace('"', '\\"')

            if ctx.check_mode:
                return {"changed": True, "msg": "would create user %s" % userid}

            curl_args = [
                "curl", "-sS", "-XPOST",
                "-H", "Content-Type: application/json",
                "-H", "Authorization: " + auth_header,
                "-d", payload,
                url + "/api/users"
            ]
            res = ctx.run(curl_args, mutates=True)
            if res.rc != 0:
                fail("failed to create user %s: %s" % (userid, res.stderr))
            return {"changed": True, "msg": "created user %s" % userid}

        else:
            # Update existing user
            # Check if update is needed
            need_update = False

            if name != None:
                # Get current name
                curr_name = user.get("name")
                if curr_name != None and name != curr_name:
                    need_update = True

            # Password update policy
            if password != None:
                if update_password == "always":
                    need_update = True
                elif update_password == "on_create":
                    pass

            if email != None:
                curr_email = user.get("email")
                if curr_email != None and email != curr_email:
                    need_update = True

            if group != None:
                # Resolve group id
                group_id = None
                curl_args = [
                    "curl", "-sS", "-XGET",
                    "-H", "Content-Type: application/json",
                    "-H", "Authorization: " + auth_header,
                    url + "/api/groups?expand=resources&filter[]=" + group
                ]
                res = ctx.run(curl_args, mutates=False)
                if res.rc != 0:
                    fail("failed to query groups: " + res.stderr)
                stdout = res.stdout
                res_idx = stdout.find('"resources"')
                if res_idx != -1:
                    bracket_start = stdout.find('[', res_idx)
                    if bracket_start != -1:
                        obj_start = stdout.find('{', bracket_start)
                        if obj_start != -1:
                            depth = 1
                            i = obj_start + 1
                            while i < len(stdout) and depth > 0:
                                if stdout[i] == '{':
                                    depth += 1
                                elif stdout[i] == '}':
                                    depth -= 1
                                i += 1
                            if depth == 0:
                                obj_str = stdout[obj_start:i]
                                id_idx = obj_str.find('"id"')
                                if id_idx != -1:
                                    eq_idx = obj_str.find(':', id_idx)
                                    if eq_idx != -1:
                                        val_start = eq_idx + 1
                                        while val_start < len(obj_str) and obj_str[val_start] in (' ', '\t', '\n'):
                                            val_start += 1
                                        if val_start < len(obj_str) and obj_str[val_start].isdigit():
                                            val_end = val_start
                                            while val_end < len(obj_str) and obj_str[val_end].isdigit():
                                                val_end += 1
                                            group_id = int(obj_str[val_start:val_end])

                if group_id == None:
                    fail("group %s not found" % group)

                curr_group_id = user.get("group_id")
                if curr_group_id != None and str(curr_group_id) != str(group_id):
                    need_update = True

            if not need_update:
                return {"changed": False, "msg": "user %s is up to date" % userid}

            # Build update payload
            payload = '{"userid":"%s"' % userid.replace('"', '\\"')
            if name != None:
                payload += ',"name":"%s"' % name.replace('"', '\\"')
            if email != None:
                payload += ',"email":"%s"' % email.replace('"', '\\"')
            if group != None:
                payload += ',"group":{"id":%s}' % str(group_id)
            if password != None and update_password == "always":
                payload += ',"password":"%s"' % password.replace('"', '\\"')
            payload += '}'

            if ctx.check_mode:
                return {"changed": True, "msg": "would update user %s" % userid}

            curl_args = [
                "curl", "-sS", "-XPOST",
                "-H", "Content-Type: application/json",
                "-H", "Authorization: " + auth_header,
                "-d", payload,
                url + "/api/users/" + user["id"] + "?action=edit"
            ]
            res = ctx.run(curl_args, mutates=True)
            if res.rc != 0:
                fail("failed to update user %s: %s" % (userid, res.stderr))
            return {"changed": True, "msg": "updated user %s" % userid}

    fail("unexpected state: " + state)
