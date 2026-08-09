def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    organization = params.get("organization")
    api_url = params.get("api_url", "https://api.github.com")
    force_defaults = params.get("force_defaults", True)
    access_token = params.get("access_token")
    username = params.get("username")
    password = params.get("password")
    description = params.get("description")
    private = params.get("private")

    # Validate authentication
    has_token = access_token != None
    has_creds = username != None and password != None
    if not has_token and not has_creds:
        fail("one of the following is required: access_token, username,password")
    if has_token and has_creds:
        fail("parameters are mutually exclusive: access_token, username,password")

    # Apply force_defaults defaults
    if force_defaults:
        if description == None:
            description = ""
        if private == None:
            private = False
    else:
        if description == None:
            description = ""
        if private == None:
            private = False

    # Prepare authentication header
    if has_token:
        auth_header = "token " + access_token
    else:
        # Basic auth: base64("username:password")
        auth_string = username + ":" + password
        # Manual base64 implementation (no stdlib)
        base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        encoded = ""
        i = 0
        while i < len(auth_string):
            c1 = ord(auth_string[i])
            i += 1
            c2 = 0
            c3 = 0
            if i < len(auth_string):
                c2 = ord(auth_string[i])
                i += 1
            if i < len(auth_string):
                c3 = ord(auth_string[i])
                i += 1

            encoded += base64_chars[(c1 >> 2) & 0x3F]
            encoded += base64_chars[((c1 & 0x03) << 4) | (c2 >> 4)]
            if i <= len(auth_string):
                encoded += base64_chars[((c2 & 0x0F) << 2) | (c3 >> 6)]
            if i <= len(auth_string) + 1:
                encoded += base64_chars[c3 & 0x3F]
            else:
                encoded += "=="
                break

        # Remove padding and trailing =
        if len(auth_string) % 3 == 1:
            encoded = encoded[:-2] + "=="
        elif len(auth_string) % 3 == 2:
            encoded = encoded[:-1] + "="
        else:
            encoded = encoded[:-2]

        auth_header = "Basic " + encoded

    headers = [
        "-H", "Authorization: " + auth_header,
        "-H", "Accept: application/vnd.github.v3+json"
    ]

    def api_call(method, path, body=None, mutates=False):
        url = base_url + path
        argv = ["curl", "-s", "-X", method] + headers + [url]
        if body:
            argv.extend(["-d", body])
        res = ctx.run(argv, mutates=mutates)
        if res.rc != 0:
            fail("API call failed: " + res.stderr)
        return res

    base_url = api_url.rstrip("/")

    # Find repo
    org_path = "orgs/" + organization + "/repos" if organization else "user/repos"
    list_path = "/" + org_path + "?per_page=100"
    res = api_call("GET", list_path, mutates=False)
    repos = []
    content = res.stdout
    if not content:
        content = "[]"
    # Parse JSON manually: extract "name": "..."
    content = content.strip()
    if content.startswith("[") and content.endswith("]"):
        content = content[1:-1]
    items = []
    depth = 0
    start = 0
    for i, c in enumerate(content):
        if c == '{':
            if depth == 0:
                start = i
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                items.append(content[start:i+1])
    for item in items:
        name_key = '"name":'
        idx = item.find(name_key)
        if idx >= 0:
            start_idx = idx + len(name_key)
            # Skip whitespace and quotes
            while start_idx < len(item) and item[start_idx] in ' \t\n\r"':
                start_idx += 1
            end_idx = start_idx
            while end_idx < len(item) and item[end_idx] not in '",\n\r':
                end_idx += 1
            repo_name = item[start_idx:end_idx]
            repos.append(repo_name)

    repo_exists = name in repos

    if state == "absent":
        if not repo_exists:
            return {"changed": False, "msg": "repository does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete repository " + name}
        path = "/repos/" + (organization + "/" if organization else "") + name
        api_call("DELETE", path, mutates=True)
        return {"changed": True, "msg": "deleted repository " + name}

    # state == "present"
    if repo_exists:
        # Check and update if needed
        path = "/repos/" + (organization + "/" if organization else "") + name
        res = api_call("GET", path, mutates=False)
        content = res.stdout
        # Extract current private and description from JSON
        private_key = '"private":'
        desc_key = '"description":'

        def get_json_field(json_str, key):
            idx = json_str.find(key)
            if idx < 0:
                return None
            start = idx + len(key)
            while start < len(json_str) and json_str[start] in ' \t\n\r':
                start += 1
            # Handle booleans first
            if json_str[start:].startswith("true"):
                return True
            if json_str[start:].startswith("false"):
                return False
            if json_str[start] != '"':
                return None
            start += 1
            end = start
            while end < len(json_str) and json_str[end] != '"':
                end += 1
            return json_str[start:end]

        current_private = get_json_field(content, private_key)
        current_desc = get_json_field(content, desc_key)

        # Apply force_defaults logic: treat null/None as empty/false
        if current_desc == None:
            current_desc = ""
        if current_private == None:
            current_private = False

        # Determine if changes needed
        need_update = False
        if current_desc != description:
            need_update = True
        if current_private != private:
            need_update = True

        if not need_update:
            return {"changed": False, "msg": "repository already exists with desired attributes"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would update repository " + name}
        # PATCH update
        # Manually build JSON body
        escaped_name = name.replace("\\", "\\\\").replace('"', '\\"')
        escaped_desc = description.replace("\\", "\\\\").replace('"', '\\"')
        body = '{"name": "' + escaped_name + '", "private": ' + ("true" if private else "false") + ', "description": "' + escaped_desc + '"}'
        api_call("PATCH", path, body, mutates=True)
        return {"changed": True, "msg": "updated repository " + name}

    # Create new repo
    if ctx.check_mode:
        return {"changed": True, "msg": "would create repository " + name}
    path = "/" + org_path
    escaped_name = name.replace("\\", "\\\\").replace('"', '\\"')
    escaped_desc = description.replace("\\", "\\\\").replace('"', '\\"')
    body = '{"name": "' + escaped_name + '", "private": ' + ("true" if private else "false") + ', "description": "' + escaped_desc + '"}'
    api_call("POST", path, body, mutates=True)
    return {"changed": True, "msg": "created repository " + name}
