def main(ctx, params):
    # Validate required parameters
    username = params.get("username")
    if not username:
        fail("username is required")

    state = params.get("state", "present")
    if state not in ["present", "absent", "blocked", "unblocked"]:
        fail("state must be one of: present, absent, blocked, unblocked")

    if state == "present":
        name = params.get("name")
        email = params.get("email")
        if not name:
            fail("name is required when state=present")
        if not email:
            fail("email is required when state=present")

    # Build GitLab API URL
    api_url = params.get("api_url", "https://gitlab.com/api/v4")
    if not api_url.startswith("http"):
        fail("api_url must start with http:// or https://")

    # Prepare authentication
    api_token = params.get("api_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    api_oauth_token = params.get("api_oauth_token")
    api_job_token = params.get("api_job_token")

    # Only basic auth or token-based auth supported
    if api_username:
        if not api_password:
            fail("api_password is required when api_username is provided")
        auth = "Basic " + api_username + ":" + api_password
    elif api_token:
        auth = "Bearer " + api_token
    elif api_oauth_token:
        auth = "Bearer " + api_oauth_token
    elif api_job_token:
        auth = "Bearer " + api_job_token
    else:
        fail("One of api_token, api_username, api_oauth_token, or api_job_token is required")

    # Prepare headers list
    headers = ["Authorization:" + auth, "Content-Type:application/json"]

    # Helper to run curl commands
    def run_curl(url, method="GET", body=None):
        args = ["curl", "-s", "-w", "%{http_code}", "-o", "/dev/stdout"]
        args.append("-X")
        args.append(method)
        for h in headers:
            args.append("-H")
            args.append(h)
        if body:
            args.append("-d")
            args.append(body)
        args.append(url)
        res = ctx.run(args, mutates=(method != "GET"))
        if res.skipped:
            return {"rc": 0, "stdout": "", "stderr": "", "skipped": True}
        if res.rc != 0:
            fail("curl failed: " + res.stderr)
        # Extract HTTP status code from last line of output
        lines = res.stdout.split("\n")
        http_code = lines[-1] if lines else "000"
        body_output = "\n".join(lines[:-1]) if len(lines) > 1 else ""
        return {"rc": int(http_code), "stdout": body_output, "stderr": res.stderr}

    # Helper to check if user exists
    def user_exists(username):
        url = api_url + "/users?search=" + username
        res = run_curl(url, method="GET")
        if res.skipped:
            return False
        if res.rc != 200:
            fail("Failed to list users: " + res.stderr)
        return ("\"username\":\"" + username + "\"" in res.stdout or 
                "\"username\": \"" + username + "\"" in res.stdout)

    # Helper to get user details
    def get_user_by_username(username):
        url = api_url + "/users?search=" + username
        res = run_curl(url, method="GET")
        if res.skipped:
            return None
        if res.rc != 200:
            fail("Failed to list users: " + res.stderr)
        # Find user id using simple string search
        if "\"username\":\"" + username + "\"" not in res.stdout:
            return None
        # Extract id (simplified approach)
        idx = res.stdout.find("\"username\":\"" + username + "\"")
        if idx == -1:
            return None
        snippet = res.stdout[idx:]
        idx2 = snippet.find("\"id\":")
        if idx2 == -1:
            return None
        snippet2 = snippet[idx2 + 5:]
        # Extract numeric id
        num_str = ""
        for c in snippet2:
            if c.isdigit():
                num_str = num_str + c
            else:
                break
        if num_str == "":
            return None
        return int(num_str)

    # Helper to get full user details
    def get_user_details(user_id):
        url = api_url + "/users/" + str(user_id)
        res = run_curl(url, method="GET")
        if res.skipped:
            return ""
        if res.rc != 200:
            fail("Failed to get user details: " + res.stderr)
        return res.stdout

    # Helper to create user
    def create_user(data):
        url = api_url + "/users"
        res = run_curl(url, method="POST", body=data)
        if res.skipped:
            return True
        if res.rc != 201:
            fail("Failed to create user: " + res.stderr)
        return True

    # Helper to update user
    def update_user(user_id, data):
        url = api_url + "/users/" + str(user_id)
        res = run_curl(url, method="PUT", body=data)
        if res.skipped:
            return True
        if res.rc != 200:
            fail("Failed to update user: " + res.stderr)
        return True

    # Helper to delete user
    def delete_user(user_id):
        url = api_url + "/users/" + str(user_id)
        res = run_curl(url, method="DELETE")
        if res.skipped:
            return True
        if res.rc != 204:
            fail("Failed to delete user: " + res.stderr)
        return True

    # Helper to block user
    def block_user(user_id):
        url = api_url + "/users/" + str(user_id) + "/block"
        res = run_curl(url, method="POST")
        if res.skipped:
            return True
        if res.rc != 200:
            fail("Failed to block user: " + res.stderr)
        return True

    # Helper to unblock user
    def unblock_user(user_id):
        url = api_url + "/users/" + str(user_id) + "/unblock"
        res = run_curl(url, method="POST")
        if res.skipped:
            return True
        if res.rc != 200:
            fail("Failed to unblock user: " + res.stderr)
        return True

    # Helper to add SSH key
    def add_ssh_key(user_id, name, key, expires_at):
        url = api_url + "/users/" + str(user_id) + "/keys"
        if expires_at:
            data = '{"title":"' + name + '","key":"' + key + '","expires_at":"' + expires_at + '"}'
        else:
            data = '{"title":"' + name + '","key":"' + key + '"}'
        res = run_curl(url, method="POST", body=data)
        if res.skipped:
            return True
        if res.rc != 201:
            fail("Failed to add SSH key: " + res.stderr)
        return True

    # Helper to add user to group
    def add_user_to_group(group_id, user_id, access_level):
        url = api_url + "/groups/" + str(group_id) + "/members"
        level_map = {
            "guest": 10,
            "reporter": 20,
            "developer": 30,
            "master": 40,
            "maintainer": 40,
            "owner": 50,
        }
        level = level_map.get(access_level, 10)
        data = '{"user_id":' + str(user_id) + ',"access_level":' + str(level) + '}'
        res = run_curl(url, method="POST", body=data)
        if res.skipped:
            return True
        if res.rc != 201:
            fail("Failed to add user to group: " + res.stderr)
        return True

    # Helper to get group ID from path
    def get_group_id(group_path):
        url = api_url + "/groups?search=" + group_path
        res = run_curl(url, method="GET")
        if res.skipped:
            return None
        if res.rc != 200:
            fail("Failed to get group: " + res.stderr)
        if group_path in res.stdout:
            idx = res.stdout.find("\"id\":")
            if idx != -1:
                snippet = res.stdout[idx + 5:]
                num_str = ""
                for c in snippet:
                    if c.isdigit():
                        num_str = num_str + c
                    else:
                        break
                if num_str != "":
                    return int(num_str)
        return None

    # Check user state
    user_id = get_user_by_username(username)
    
    if state == "absent":
        if user_id == None:
            return {"changed": False, "msg": "User does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "Would delete user " + username}
        delete_user(user_id)
        return {"changed": True, "msg": "Successfully deleted user " + username}

    if state == "blocked":
        if user_id == None:
            return {"changed": False, "msg": "User does not exist"}
        details = get_user_details(user_id)
        is_active = '"state":"active"' in details
        if not is_active:
            return {"changed": False, "msg": "User already blocked or does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "Would block user " + username}
        block_user(user_id)
        return {"changed": True, "msg": "Successfully blocked user " + username}

    if state == "unblocked":
        if user_id == None:
            return {"changed": False, "msg": "User does not exist"}
        details = get_user_details(user_id)
        is_active = '"state":"active"' in details
        if is_active:
            return {"changed": False, "msg": "User is not blocked or does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "Would unblock user " + username}
        unblock_user(user_id)
        return {"changed": True, "msg": "Successfully unblocked user " + username}

    # State == "present"
    name = params.get("name")
    email = params.get("email")
    password = params.get("password")
    reset_password = params.get("reset_password", False)
    sshkey_name = params.get("sshkey_name")
    sshkey_file = params.get("sshkey_file")
    sshkey_expires_at = params.get("sshkey_expires_at")
    group = params.get("group")
    access_level = params.get("access_level", "guest")
    confirm = params.get("confirm", True)
    isadmin = params.get("isadmin", False)
    external = params.get("external", False)

    # Build user payload JSON
    payload = '{"username":"' + username + '","name":"' + name + '","email":"' + email + '"'
    if password:
        payload = payload + ',"password":"' + password + '"'
    payload = payload + ',"reset_password":' + str(reset_password).lower()
    payload = payload + ',"skip_reconfirmation":' + str(not confirm).lower()
    payload = payload + ',"admin":' + str(isadmin).lower()
    payload = payload + ',"external":' + str(external).lower() + '}'

    if user_id == None:
        # Create user
        if ctx.check_mode:
            return {"changed": True, "msg": "Would create user " + username}
        create_user(payload)
        user_id = get_user_by_username(username)
        if user_id == None:
            fail("Failed to retrieve newly created user")

        # Add SSH key if provided
        if sshkey_name and sshkey_file:
            add_ssh_key(user_id, sshkey_name, sshkey_file, sshkey_expires_at)

        # Add to group if specified
        if group:
            group_id = get_group_id(group)
            if group_id:
                add_user_to_group(group_id, user_id, access_level)

        return {"changed": True, "msg": "Successfully created user " + username}

    # User exists - check for updates
    details = get_user_details(user_id)

    # Check if updates needed
    needs_update = False
    if '"name":"' + name + '"' not in details or '"email":"' + email + '"' not in details:
        needs_update = True
    if '"admin":' + str(isadmin).lower() not in details:
        needs_update = True
    if '"external":' + str(external).lower() not in details:
        needs_update = True
    if '"reset_password":' + str(reset_password).lower() not in details:
        needs_update = True

    if needs_update:
        if ctx.check_mode:
            return {"changed": True, "msg": "Would update user " + username}
        update_user(user_id, payload)

        # Update SSH key if provided
        if sshkey_name and sshkey_file:
            add_ssh_key(user_id, sshkey_name, sshkey_file, sshkey_expires_at)

        # Update group membership if specified
        if group:
            group_id = get_group_id(group)
            if group_id:
                add_user_to_group(group_id, user_id, access_level)

        return {"changed": True, "msg": "Successfully updated user " + username}
    else:
        # Check SSH key and group membership
        ssh_changed = False
        group_changed = False

        if sshkey_name and sshkey_file:
            ssh_url = api_url + "/users/" + str(user_id) + "/keys"
            ssh_res = run_curl(ssh_url, method="GET")
            if sshkey_name not in ssh_res.stdout:
                ssh_changed = True

        if group and not ssh_changed:
            group_id = get_group_id(group)
            if group_id:
                member_url = api_url + "/groups/" + str(group_id) + "/members/" + str(user_id)
                member_res = run_curl(member_url, method="GET")
                if member_res.rc != 200:
                    group_changed = True

        if ssh_changed or group_changed:
            if ctx.check_mode:
                return {"changed": True, "msg": "Would update user " + username}
            if ssh_changed and sshkey_name and sshkey_file:
                add_ssh_key(user_id, sshkey_name, sshkey_file, sshkey_expires_at)
            if group_changed and group:
                group_id = get_group_id(group)
                if group_id:
                    add_user_to_group(group_id, user_id, access_level)
            return {"changed": True, "msg": "Successfully updated user " + username}
        else:
            return {"changed": False, "msg": "User exists and is up to date"}
