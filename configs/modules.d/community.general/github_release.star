def main(ctx, params):
    action = params["action"]
    user = params["user"]
    repo = params["repo"]
    password = params.get("password")
    token = params.get("token")
    tag = params.get("tag")
    target = params.get("target")
    name = params.get("name")
    body = params.get("body")
    draft = params.get("draft", False)
    prerelease = params.get("prerelease", False)

    # Validation: mutual exclusion of password and token
    if password != None and token != None:
        fail("password and token are mutually exclusive")

    if action == "create_release":
        if tag == None:
            fail("tag is required when action is create_release")
        if password == None and token == None:
            fail("one of token or password is required for create_release")

    # Construct HTTP headers for GitHub API
    headers = [
        "Accept", "application/vnd.github.v3+json",
        "User-Agent", "yolo-man-agent"
    ]
    if token != None:
        headers.extend(["Authorization", "token " + token])
    elif password != None:
        # Build base64("user:password") manually without import
        s = user + ":" + password
        b64 = ""
        # Base64 alphabet
        alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        # Process input in chunks of 3 bytes
        i = 0
        while i < len(s):
            c1 = ord(s[i]) if i < len(s) else 0
            c2 = ord(s[i+1]) if i+1 < len(s) else 0
            c3 = ord(s[i+2]) if i+2 < len(s) else 0
            b1 = (c1 >> 2) & 0x3F
            b2 = ((c1 & 0x03) << 4) | ((c2 >> 4) & 0x0F)
            b3 = ((c2 & 0x0F) << 2) | ((c3 >> 6) & 0x03)
            b4 = c3 & 0x3F
            pad = 0
            if i+1 >= len(s): pad = 2
            elif i+2 >= len(s): pad = 1
            if pad == 0:
                b64 = b64 + alphabet[b1] + alphabet[b2] + alphabet[b3] + alphabet[b4]
            elif pad == 1:
                b64 = b64 + alphabet[b1] + alphabet[b2] + alphabet[b3] + "="
            else:
                b64 = b64 + alphabet[b1] + alphabet[b2] + "=="
            i = i + 3
        headers.extend(["Authorization", "Basic " + b64])

    # Helper: perform curl request
    def curl(method, path, data=None):
        url = "https://api.github.com" + path
        args = ["curl", "-s", "-X", method, "-H", "Accept: application/vnd.github.v3+json"]
        i = 0
        while i < len(headers):
            args.extend(["-H", headers[i] + ": " + headers[i+1]])
            i = i + 2
        if data != None:
            args.extend(["-d", data])
        args.append(url)
        res = ctx.run(args, mutates=(method != "GET"))
        if res.rc != 0:
            fail("github api call failed: " + res.stderr)
        return res

    # Action: latest_release
    if action == "latest_release":
        path = "/repos/" + user + "/" + repo + "/releases/latest"
        res = curl("GET", path)
        if res.stdout == "":
            return {"changed": False, "tag": None}
        # parse tag_name from JSON response manually
        tag_name = None
        for line in res.stdout.split("\n"):
            stripped = line.strip()
            if stripped.startswith("\"tag_name\""):
                idx = stripped.find(":")
                val = stripped[idx+1:].strip().strip("\"")
                tag_name = val
                break
        return {"changed": False, "tag": tag_name}

    # Action: create_release
    if action == "create_release":
        # Check if release for this tag already exists
        path = "/repos/" + user + "/" + repo + "/releases/tags/" + tag
        check_res = curl("GET", path)
        if check_res.rc == 0 and check_res.stdout != "":
            return {"changed": False, "msg": "Release for tag " + tag + " already exists.", "tag": tag}

        # Prepare JSON payload (no json module; build manually)
        parts = []
        parts.append("\"tag_name\": \"" + tag.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")
        target_val = target if target != None else "master"
        parts.append("\"target_commitish\": \"" + target_val.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")
        if name != None:
            parts.append("\"name\": \"" + name.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")
        if body != None:
            parts.append("\"body\": \"" + body.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")
        parts.append("\"draft\": " + ("true" if draft else "false"))
        parts.append("\"prerelease\": " + ("true" if prerelease else "false"))
        json_str = "{" + ", ".join(parts) + "}"

        # POST /repos/{owner}/{repo}/releases
        post_path = "/repos/" + user + "/" + repo + "/releases"
        res = curl("POST", post_path, json_str)
        if res.skipped:
            return {"changed": True, "msg": "would create release for tag " + tag, "tag": tag}
        if res.rc != 0:
            fail("failed to create release: " + res.stderr)

        # Parse response to extract tag_name
        if res.stdout == "":
            return {"changed": False, "msg": "release creation response empty", "tag": None}

        tag_name = None
        for line in res.stdout.split("\n"):
            stripped = line.strip()
            if stripped.startswith("\"tag_name\""):
                idx = stripped.find(":")
                val = stripped[idx+1:].strip().strip("\"")
                tag_name = val
                break

        if tag_name == None:
            fail("could not parse tag_name from release creation response")

        return {"changed": True, "msg": "created release " + tag_name, "tag": tag_name}

    fail("unsupported action: " + action)
