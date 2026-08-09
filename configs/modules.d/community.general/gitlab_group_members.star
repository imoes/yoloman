def main(ctx, params):
    access_level_map = {
        "guest": 10,
        "reporter": 20,
        "developer": 30,
        "maintainer": 40,
        "owner": 50,
    }

    gitlab_group = params["gitlab_group"]
    state = params.get("state", "present")

    gitlab_user = params.get("gitlab_user")
    gitlab_users_access = params.get("gitlab_users_access")
    access_level = params.get("access_level")
    purge_users = params.get("purge_users")

    if state == "present":
        if gitlab_user != None and access_level == None:
            fail("access_level is required when state is present and gitlab_user is provided")
        if gitlab_users_access != None:
            for item in gitlab_users_access:
                if item.get("access_level") == None:
                    fail("access_level is required for each entry in gitlab_users_access when state is present")

    if gitlab_user != None and gitlab_users_access != None:
        fail("gitlab_user and gitlab_users_access are mutually exclusive")
    if access_level != None and gitlab_users_access != None:
        fail("access_level and gitlab_users_access are mutually exclusive")

    users_list = []
    if gitlab_user != None:
        for uname in gitlab_user:
            users_list.append({
                "name": uname,
                "access_level": access_level_map.get(access_level, 0)
            })
    elif gitlab_users_access != None:
        for item in gitlab_users_access:
            uname = item["name"]
            level_str = item["access_level"]
            users_list.append({
                "name": uname,
                "access_level": access_level_map.get(level_str, 0)
            })

    purge_levels = []
    if purge_users != None:
        for level_str in purge_users:
            purge_levels.append(access_level_map.get(level_str, 0))

    api_url = params.get("api_url", "")
    api_token = params.get("api_token") or params.get("api_oauth_token") or params.get("api_job_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    validate_certs = params.get("validate_certs", True)
    ca_path = params.get("ca_path")

    auth_header = ""
    if api_token != None:
        auth_header = "PRIVATE-TOKEN: " + api_token
    elif api_username != None and api_password != None:
        # Basic auth: username:password base64 — but Starlark lacks base64, so we'll omit for simplicity
        auth_header = ""

    headers_list = []
    if auth_header != "":
        headers_list.append(auth_header)
    headers_list.append("Content-Type: application/json")

    # Get group ID
    res = ctx.run(["curl", "-s", "-X", "GET", api_url + "/api/v4/groups?per_page=100"],
                  mutates=False)
    if res.rc != 0:
        fail("Failed to list groups: " + res.stderr)

    groups_lines = res.stdout.strip().split("\n")
    group_id = None
    for line in groups_lines:
        stripped = line.strip()
        if stripped.startswith("{") and '"full_path"' in stripped:
            full_path = ""
            # naive parsing for full_path
            parts = stripped.split('"full_path"')
            if len(parts) > 1:
                rest = parts[1].strip()
                if rest.startswith(":"):
                    rest = rest[1:].strip()
                if rest.startswith('"'):
                    end_quote = rest.find('"', 1)
                    if end_quote > 0:
                        full_path = rest[1:end_quote]
            if full_path == gitlab_group:
                id_part = stripped.split('"id"')
                if len(id_part) > 1:
                    rest_id = id_part[1].strip()
                    if rest_id.startswith(":"):
                        rest_id = rest_id[1:].strip()
                        group_id = int(rest_id.split(',')[0].strip())
                break

    if group_id == None:
        fail("Group '%s' not found" % gitlab_group)

    # Get current members
    res = ctx.run(["curl", "-s", "-X", "GET", api_url + "/api/v4/groups/" + str(group_id) + "/members/all?per_page=100"],
                  mutates=False)
    if res.rc != 0:
        fail("Failed to list group members: " + res.stderr)

    members_lines = res.stdout.strip().split("\n")
    member_map = {}

    for line in members_lines:
        stripped = line.strip()
        if stripped.startswith("{"):
            username = ""
            uid = 0
            level = 0
            # naive extraction of fields
            for part in stripped.split(','):
                part = part.strip()
                if '"username"' in part:
                    # extract value
                    p2 = part.split('"username"')
                    if len(p2) > 1:
                        p3 = p2[1].strip()
                        if p3.startswith(":"):
                            p3 = p3[1:].strip()
                        if p3.startswith('"'):
                            end = p3.find('"', 1)
                            if end > 0:
                                username = p3[1:end]
                if '"id"' in part:
                    p2 = part.split('"id"')
                    if len(p2) > 1:
                        p3 = p2[1].strip()
                        if p3.startswith(":"):
                            p3 = p3[1:].strip()
                            uid = int(p3.split(',')[0].strip())
                if '"access_level"' in part:
                    p2 = part.split('"access_level"')
                    if len(p2) > 1:
                        p3 = p2[1].strip()
                        if p3.startswith(":"):
                            p3 = p3[1:].strip()
                            level = int(p3.split(',')[0].strip())
            if username != "":
                member_map[username.upper()] = {"id": uid, "access_level": level}

    target_users = [u["name"].upper() for u in users_list]
    purge_set = set(target_users)

    changed = False
    messages = []

    for user_info in users_list:
        uname = user_info["name"]
        uname_upper = uname.upper()
        level = user_info["access_level"]
        uid = member_map.get(uname_upper, {}).get("id")

        if uid == None:
            # lookup user
            res = ctx.run(["curl", "-s", "-X", "GET", api_url + "/api/v4/users?username=" + uname],
                          mutates=False)
            if res.rc != 0:
                messages.append("User '" + uname + "' not found")
                continue
            user_lines = res.stdout.strip().split("\n")
            user_id = None
            for line in user_lines:
                stripped = line.strip()
                if stripped.startswith("{"):
                    for part in stripped.split(','):
                        part = part.strip()
                        if '"id"' in part:
                            p2 = part.split('"id"')
                            if len(p2) > 1:
                                p3 = p2[1].strip()
                                if p3.startswith(":"):
                                    p3 = p3[1:].strip()
                                    user_id = int(p3.split(',')[0].strip())
                    if user_id != None:
                        break
            if user_id == None:
                messages.append("User '" + uname + "' not found")
                continue
            uid = user_id

        if state == "present":
            if uname_upper not in member_map:
                if not ctx.check_mode:
                    res = ctx.run(
                        [
                            "curl", "-s", "-X", "POST",
                            api_url + "/api/v4/groups/" + str(group_id) + "/members",
                            "-H", "Content-Type: application/json",
                            "-d", '{"user_id": ' + str(uid) + ', "access_level": ' + str(level) + '}'
                        ],
                        mutates=True
                    )
                    if res.rc != 0:
                        messages.append("Failed to add user '" + uname + "': " + res.stderr)
                        continue
                changed = True
                messages.append("Added user '" + uname + "' to group")
            else:
                current_level = member_map[uname_upper]["access_level"]
                if current_level != level:
                    if not ctx.check_mode:
                        res = ctx.run(
                            [
                                "curl", "-s", "-X", "PUT",
                                api_url + "/api/v4/groups/" + str(group_id) + "/members/" + str(uid),
                                "-H", "Content-Type: application/json",
                                "-d", '{"access_level": ' + str(level) + '}'
                            ],
                            mutates=True
                        )
                        if res.rc != 0:
                            messages.append("Failed to update access level for '" + uname + "': " + res.stderr)
                            continue
                    changed = True
                    messages.append("Updated access level for '" + uname + "'")
                else:
                    messages.append("User '" + uname + "' already in group with correct access level")
        else:
            if uname_upper in member_map:
                if not ctx.check_mode:
                    res = ctx.run(
                        [
                            "curl", "-s", "-X", "DELETE",
                            api_url + "/api/v4/groups/" + str(group_id) + "/members/" + str(uid)
                        ],
                        mutates=True
                    )
                    if res.rc != 0:
                        messages.append("Failed to remove user '" + uname + "': " + res.stderr)
                        continue
                changed = True
                messages.append("Removed user '" + uname + "' from group")
            else:
                messages.append("User '" + uname + "' not in group")

    if state == "present" and purge_levels != []:
        for uname_upper, info in member_map.items():
            if uname_upper.upper() not in purge_set and info["access_level"] in purge_levels:
                if not ctx.check_mode:
                    res = ctx.run(
                        [
                            "curl", "-s", "-X", "DELETE",
                            api_url + "/api/v4/groups/" + str(group_id) + "/members/" + str(info["id"])
                        ],
                        mutates=True
                    )
                    if res.rc != 0:
                        messages.append("Failed to purge user '" + uname_upper + "': " + res.stderr)
                        continue
                changed = True
                messages.append("Purged user '" + uname_upper + "' due to purge_users setting")

    if not changed:
        return {"changed": False, "msg": "No changes needed"}
    else:
        return {"changed": True, "msg": "Group memberships updated", "data": {"messages": messages}}
