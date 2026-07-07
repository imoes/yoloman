def main(ctx, params):
    name = params.get("name")
    repository = params.get("repository")
    workspace = params.get("workspace")
    key_param = params.get("key")
    state = params.get("state")
    user = params.get("user") or params.get("username")
    password = params.get("password")

    if not name or not repository or not workspace or not state:
        fail("missing required arguments: name, repository, workspace, and state are required")

    if state not in ("present", "absent"):
        fail("state must be 'present' or 'absent'")

    base_url = "https://api.bitbucket.org/2.0"
    list_url = "{base}/repositories/{ws}/{repo}/pipelines_config/ssh/known_hosts/".format(base=base_url, ws=workspace, repo=repository)

    # Basic auth header construction without imports
    auth_str = user + ":" + password
    # Base64 manually: encode each 3-byte group to 4 chars
    base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    def base64_encode(s):
        result = ""
        i = 0
        while i < len(s):
            b1 = ord(s[i]) if i < len(s) else 0
            b2 = ord(s[i+1]) if i+1 < len(s) else 0
            b3 = ord(s[i+2]) if i+2 < len(s) else 0
            result += base64_chars[(b1 >> 2) & 63]
            result += base64_chars[((b1 & 3) << 4) | (b2 >> 4)]
            if i + 1 < len(s):
                result += base64_chars[((b2 & 15) << 2) | (b3 >> 6)]
            else:
                result += "="
            if i + 2 < len(s):
                result += base64_chars[b3 & 63]
            else:
                result += "="
            i += 3
        return result

    auth_header = "Basic " + base64_encode(auth_str)

    # Fetch existing hosts via pagination
    url = list_url
    existing_host = None
    visited = set()
    while url and url not in visited:
        visited.add(url)
        curl_cmd = [
            "curl", "-s", "-S", "-H", "Accept: application/json",
            "-H", "Authorization: " + auth_header, url
        ]
        res = ctx.run(curl_cmd, mutates=False)
        if res.rc != 0:
            if res.rc == 22 and "404" in res.stdout:
                fail("repository or workspace not found: {ws}/{repo}".format(ws=workspace, repo=repository))
            fail("failed to list known hosts: " + res.stderr)

        data = res.stdout
        if '"values"' not in data:
            fail("unexpected API response: missing values")

        # Extract next link (simple string search)
        next_idx = data.find('"next": "')
        if next_idx == -1:
            url = None
        else:
            start = next_idx + len('"next": "')
            end = data.find('"', start)
            url = data[start:end] if end != -1 else None

        # Search for hostname
        search_str = '"hostname": "' + name + '"'
        pos = data.find(search_str)
        if pos != -1:
            # Extract UUID (nearest preceding uuid field)
            uuid_idx = data.rfind('"uuid": "', 0, pos)
            if uuid_idx != -1:
                uuid_start = uuid_idx + len('"uuid": "')
                uuid_end = data.find('"', uuid_start)
                uuid = data[uuid_start:uuid_end]
                existing_host = {"uuid": uuid}
            break

    # Handle state
    if state == "present":
        if existing_host != None:
            return {"changed": False, "msg": "known host already exists"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would create known host " + name}

        # Prepare key
        key_type = None
        key = None
        if key_param == None:
            # Use ssh-keyscan
            res = ctx.run(["ssh-keyscan", "-t", "rsa", name], mutates=False)
            if res.rc != 0 or not res.stdout.strip():
                fail("failed to retrieve SSH key for " + name)
            lines = res.stdout.strip().split("\n")
            line = lines[-1] if len(lines) > 0 else ""
            parts = line.split()
            if len(parts) >= 2:
                key_type = parts[0]
                if key_type in ("ssh-rsa", "ssh-ed25519") and len(parts) > 1:
                    key = parts[1]
                else:
                    fail("unsupported key type: " + key_type)
            else:
                fail("could not parse public key")
        elif " " in key_param:
            key_type, key = key_param.split(" ", 1)
        else:
            fail("unknown key format: expected 'type base64'")

        # Create POST
        post_data = '{"hostname": "' + name + '", "public_key": {"key_type": "' + key_type + '", "key": "' + key + '"}}'
        curl_cmd = [
            "curl", "-s", "-S", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "Authorization: " + auth_header,
            "-d", post_data, list_url
        ]
        res = ctx.run(curl_cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would create known host " + name}
        if res.rc != 0 or "201" not in res.stdout:
            fail("failed to create known host: " + (res.stderr or res.stdout))
        return {"changed": True, "msg": "created known host " + name}

    elif state == "absent":
        if existing_host == None:
            return {"changed": False, "msg": "known host does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete known host " + name}

        delete_url = "{base}/repositories/{ws}/{repo}/pipelines_config/ssh/known_hosts/{uuid}".format(
            base=base_url, ws=workspace, repo=repository, uuid=existing_host["uuid"]
        )
        curl_cmd = [
            "curl", "-s", "-S", "-X", "DELETE",
            "-H", "Authorization: " + auth_header,
            delete_url
        ]
        res = ctx.run(curl_cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete known host " + name}
        if res.rc != 0 or "204" not in res.stdout:
            fail("failed to delete known host: " + (res.stderr or res.stdout))
        return {"changed": True, "msg": "deleted known host " + name}
