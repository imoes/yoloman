def main(ctx, params):
    name = params["name"]
    project = params["project"]
    state = params.get("state", "present")
    merge_access_levels = params.get("merge_access_levels", "maintainer")
    push_access_level = params.get("push_access_level", "maintainer")

    # Validate required options
    if merge_access_levels not in ["maintainer", "developer", "nobody"]:
        fail("merge_access_levels must be one of: maintainer, developer, nobody")
    if push_access_level not in ["maintainer", "developer", "nobody"]:
        fail("push_access_level must be one of: maintainer, developer, nobody")

    # Access level mapping
    ACCESS_LEVEL = {
        "nobody": 0,
        "developer": 30,
        "maintainer": 40
    }

    # Build GitLab API URL (default to common endpoints if not provided)
    api_url = params.get("api_url", "https://gitlab.com")
    if not api_url.startswith("http"):
        fail("api_url must start with http:// or https://")

    # Authentication: prioritize token methods
    api_token = params.get("api_token") or params.get("api_oauth_token") or params.get("api_job_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")

    # Build basic auth string if needed
    basic_auth = ""
    if api_token == None:
        if api_username == None:
            fail("One of api_token, api_oauth_token, api_job_token, or api_username is required")
        if api_password == None:
            fail("api_password is required when using api_username")
        basic_auth = api_username + ":" + api_password

    # Encode project name for URL
    project_escaped = project.replace("/", "%2F")
    list_url = api_url + "/api/v4/projects/" + project_escaped + "/protected_branches"
    branch_url = list_url + "/" + name

    # Build curl headers list
    curl_args = ["curl", "-s", "-k" if not params.get("validate_certs", True) else "", "-H", "Content-Type: application/json"]
    if api_token != None:
        curl_args.extend(["-H", "PRIVATE-TOKEN: " + api_token])
    elif basic_auth != "":
        curl_args.extend(["-u", basic_auth])

    # List protected branches
    res = ctx.run(curl_args + [list_url], mutates=False)
    if res.rc != 0:
        fail("Failed to list protected branches: " + res.stderr)

    # Parse JSON manually for "name" field presence
    existing_branches = []
    if res.stdout.strip() != "":
        # Split by "},{ or just extract all "name" occurrences
        parts = res.stdout.split('"name"')
        for i in range(1, len(parts)):
            # Next part after '"name"' should be '": "branch_name"'
            val = parts[i].strip()
            if val.startswith('":'):
                val = val[2:].strip()
                if val.startswith('"'):
                    val = val[1:]
                if val.find('"') != -1:
                    val = val[:val.find('"')]
                existing_branches.append(val)

    branch_exists = name in existing_branches

    if state == "present":
        if branch_exists:
            # Check current access levels
            res = ctx.run(curl_args + [branch_url], mutates=False)
            if res.rc == 0:
                # Extract current merge_access_level and push_access_level
                current_merge = 40
                current_push = 40
                if '"merge_access_level"' in res.stdout:
                    start = res.stdout.find('"merge_access_level"')
                    after = res.stdout[start:].split(":")[1].strip()
                    # Extract integer value
                    val_str = ""
                    for c in after:
                        if c.isdigit():
                            val_str += c
                        elif val_str != "":
                            break
                    if val_str != "":
                        current_merge = int(val_str)
                if '"push_access_level"' in res.stdout:
                    start = res.stdout.find('"push_access_level"')
                    after = res.stdout[start:].split(":")[1].strip()
                    val_str = ""
                    for c in after:
                        if c.isdigit():
                            val_str += c
                        elif val_str != "":
                            break
                    if val_str != "":
                        current_push = int(val_str)

                expected_merge = ACCESS_LEVEL[merge_access_levels]
                expected_push = ACCESS_LEVEL[push_access_level]

                if current_merge == expected_merge and current_push == expected_push:
                    return {"changed": False, "msg": "Protected branch already configured correctly"}

            # Reconfigure required
            if ctx.check_mode:
                return {"changed": True, "msg": "would update protected branch " + name}

            # Delete existing
            del_args = curl_args + ["-X", "DELETE", branch_url]
            del_res = ctx.run(del_args, mutates=True)
            if del_res.rc != 0:
                fail("Failed to delete existing protected branch: " + del_res.stderr)

            # Recreate
            data = '{"name": "' + name + '", "merge_access_level": ' + str(ACCESS_LEVEL[merge_access_levels]) + ', "push_access_level": ' + str(ACCESS_LEVEL[push_access_level]) + '}'
            create_args = curl_args + ["-X", "POST", branch_url, "-d", data]
            create_res = ctx.run(create_args, mutates=True)
            if create_res.rc != 0:
                fail("Failed to recreate protected branch: " + create_res.stderr)

            return {"changed": True, "msg": "Recreated protected branch " + name}

        # Create new
        if ctx.check_mode:
            return {"changed": True, "msg": "would create protected branch " + name}

        data = '{"name": "' + name + '", "merge_access_level": ' + str(ACCESS_LEVEL[merge_access_levels]) + ', "push_access_level": ' + str(ACCESS_LEVEL[push_access_level]) + '}'
        create_args = curl_args + ["-X", "POST", list_url, "-d", data]
        create_res = ctx.run(create_args, mutates=True)
        if create_res.rc != 0:
            fail("Failed to create protected branch: " + create_res.stderr)

        return {"changed": True, "msg": "Created protected branch " + name}

    elif state == "absent":
        if not branch_exists:
            return {"changed": False, "msg": "Protected branch does not exist"}

        if ctx.check_mode:
            return {"changed": True, "msg": "would delete protected branch " + name}

        del_args = curl_args + ["-X", "DELETE", branch_url]
        del_res = ctx.run(del_args, mutates=True)
        if del_res.rc != 0:
            fail("Failed to delete protected branch: " + del_res.stderr)

        return {"changed": True, "msg": "Deleted protected branch " + name}

    fail("Unexpected state: " + state)
