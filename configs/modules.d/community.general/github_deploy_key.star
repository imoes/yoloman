def main(ctx, params):
    github_url = params.get("github_url", "https://api.github.com")
    owner = params["owner"]
    repo = params["repo"]
    name = params["name"]
    key = params["key"]
    state = params.get("state", "present")
    read_only = params.get("read_only", True)
    force = params.get("force", False)
    username = params.get("username")
    password = params.get("password")
    token = params.get("token")
    otp = params.get("otp")

    # Validate authentication
    if token != None and password != None:
        fail("token and password are mutually exclusive")
    if username != None and password == None and token == None:
        fail("username requires either password or token")
    if otp != None and (username == None or (password == None and token == None)):
        fail("otp requires username and either password or token")

    base_url = github_url
    if base_url.endswith("/"):
        base_url = base_url[:-1]
    repo_keys_url = base_url + "/repos/" + owner + "/" + repo + "/keys"

    # Get existing deploy keys
    def get_existing_key_id():
        headers = []
        if token != None:
            headers = ["-H", "Authorization: token " + token]
        elif username != None and password != None:
            headers = ["-u", username + ":" + password]
        if otp != None:
            headers.extend(["-H", "X-GitHub-OTP: " + str(otp)])
        headers.extend(["-H", "Accept: application/vnd.github.v3+json"])
        headers.extend([repo_keys_url])

        res = ctx.run(["curl", "-s", "-S"] + headers, mutates=False)
        if res.rc != 0:
            fail("failed to list deploy keys: " + res.stderr)

        # Simple JSON parsing for deploy key list
        lines = res.stdout.split("\n")
        for line in lines:
            line = line.strip()
            if line == "" or line == "[" or line == "]" or line.startswith("{") == False:
                continue

            # Extract title, key, and id
            title_val = ""
            key_val = ""
            id_val = ""
            i = 0
            while i < len(line):
                if line[i:i+7] == '"title"':
                    j = line.find('"', i+8)
                    k = line.find('"', j+1)
                    if j != -1 and k != -1:
                        title_val = line[j+1:k]
                elif line[i:i+3] == '"id"':
                    j = line.find(':', i+3)
                    if j != -1:
                        k = j + 1
                        while k < len(line) and line[k].isdigit():
                            k += 1
                        if k > j+1:
                            id_val = line[j+1:k]
                elif line[i:i+3] == '"key"':
                    j = line.find('"', i+4)
                    k = line.find('"', j+1)
                    if j != -1 and k != -1:
                        key_val = line[j+1:k]
                i += 1

            # Normalize key for comparison
            key_parts = key.strip().split()
            existing_key_parts = key_val.strip().split()
            if (len(existing_key_parts) >= 2 and len(key_parts) >= 2 and
                existing_key_parts[0] == key_parts[0] and existing_key_parts[1] == key_parts[1]) or title_val == name:
                if id_val.isdigit():
                    return int(id_val)
                else:
                    fail("invalid deploy key ID: " + id_val)
        return None

    # Add deploy key
    def add_deploy_key():
        read_only_str = "true" if read_only else "false"
        payload = "{\"title\":\"" + name + "\",\"key\":\"" + key + "\",\"read_only\":" + read_only_str + "}"
        headers = []
        if token != None:
            headers = ["-H", "Authorization: token " + token]
        elif username != None and password != None:
            headers = ["-u", username + ":" + password]
        if otp != None:
            headers.extend(["-H", "X-GitHub-OTP: " + str(otp)])
        headers.extend(["-H", "Accept: application/vnd.github.v3+json"])
        headers.extend(["-H", "Content-Type: application/json"])
        headers.extend(["-d", payload, repo_keys_url])

        res = ctx.run(["curl", "-s", "-S", "-X", "POST"] + headers, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would add deploy key " + name}
        if res.rc != 0:
            fail("failed to add deploy key: " + res.stderr)

        # Check for success
        if '"id"' in res.stdout:
            id_str = ""
            i = 0
            while i < len(res.stdout):
                if res.stdout[i:i+5] == '"id"':
                    j = res.stdout.find(':', i)
                    if j != -1:
                        k = j + 1
                        while k < len(res.stdout) and res.stdout[k].isdigit():
                            k += 1
                        if k > j+1:
                            id_str = res.stdout[j+1:k]
                            break
                i += 1
            if id_str.isdigit():
                return {"changed": True, "msg": "Deploy key successfully added", "id": int(id_str)}
            else:
                fail("invalid deploy key ID in response: " + res.stdout)
        elif '"already in use"' in res.stdout.lower():
            return {"changed": False, "msg": "Deploy key already exists"}
        else:
            fail("unexpected response when adding deploy key: " + res.stdout)

    # Delete deploy key
    def delete_deploy_key(key_id):
        headers = []
        if token != None:
            headers = ["-H", "Authorization: token " + token]
        elif username != None and password != None:
            headers = ["-u", username + ":" + password]
        if otp != None:
            headers.extend(["-H", "X-GitHub-OTP: " + str(otp)])
        headers.extend(["-H", "Accept: application/vnd.github.v3+json"])
        headers.extend(["-X", "DELETE", repo_keys_url + "/" + str(key_id)])

        res = ctx.run(["curl", "-s", "-S"] + headers, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete deploy key " + str(key_id), "id": key_id}
        if res.rc != 0:
            fail("failed to delete deploy key " + str(key_id) + ": " + res.stderr)
        return {"changed": True, "msg": "Deploy key successfully deleted", "id": key_id}

    # Check mode
    if ctx.check_mode:
        existing_id = get_existing_key_id()
        if state == "present":
            if existing_id == None:
                return {"changed": True, "msg": "would add deploy key " + name}
            else:
                if force:
                    return {"changed": True, "msg": "would delete and re-add deploy key " + name}
                return {"changed": False, "msg": "deploy key already exists"}
        else:  # absent
            if existing_id != None:
                return {"changed": True, "msg": "would delete deploy key " + str(existing_id), "id": existing_id}
            else:
                return {"changed": False, "msg": "deploy key does not exist"}

    # Non-check mode
    existing_id = get_existing_key_id()

    if state == "absent":
        if existing_id != None:
            return delete_deploy_key(existing_id)
        else:
            return {"changed": False, "msg": "Deploy key does not exist"}

    # state == "present"
    if existing_id != None:
        if force:
            # Delete first, then add
            delete_deploy_key(existing_id)
            return add_deploy_key()
        else:
            return {"changed": False, "msg": "Deploy key already exists"}

    # No existing key and state=present
    return add_deploy_key()
