def main(ctx, params):
    user = params["user"]
    password = params.get("password")
    token = params.get("token")
    if password != None and token != None:
        fail("password and token are mutually exclusive")
    if password == None and token == None:
        fail("one of password or token is required")

    github_url = params.get("github_url", "https://api.github.com")
    repo_name = params["repository"]
    hook_url = params["url"]

    # Authentication header
    auth = ""
    if token != None:
        auth = "Bearer " + token
    elif password != None:
        auth = "Basic " + user + ":" + password  # Note: insecure but matches original logic

    # Helper: GitHub API request
    def github_request(method, path, data=None):
        headers = [
            "Authorization: " + auth,
            "Accept: application/vnd.github.v3+json",
            "Content-Type: application/json"
        ]
        body = ""
        if data != None:
            # Simple JSON serialization for Starlark
            body = "{"
            keys = data.keys()
            for i, k in enumerate(keys):
                v = data.get(k)
                if isinstance(v, bool):
                    body += '"' + k + '":' + ("true" if v else "false")
                elif isinstance(v, list):
                    body += '"' + k + '":['
                    for j, x in enumerate(v):
                        if j > 0:
                            body += ","
                        body += '"' + str(x) + '"'
                    body += "]"
                elif isinstance(v, str):
                    body += '"' + k + '":"' + v + '"'
                elif isinstance(v, int):
                    body += '"' + k + '":' + str(v)
                else:
                    fail("unsupported value type for " + k)
                if i < len(keys) - 1:
                    body += ","
            body += "}"
        res = ctx.run(
            ["curl", "-s", "-X", method, "-H", "Authorization: " + auth, "-H", "Accept: application/vnd.github.v3+json", "-H", "Content-Type: application/json", "-d", body, github_url + path],
            mutates=(method != "GET"),
            ok_codes=[0, 200, 201, 204]
        )
        if res.skipped:
            return {"rc": 0, "stdout": "", "stderr": "", "skipped": True}
        if res.rc != 0 and not res.skipped:
            fail("GitHub API call failed: " + res.stderr)
        return {"rc": res.rc, "stdout": res.stdout, "stderr": res.stderr, "skipped": False}

    # Get existing hooks
    res = github_request("GET", "/repos/" + repo_name + "/hooks")
    if res["skipped"]:
        return {"changed": True, "msg": "would list hooks"}
    stdout = res["stdout"]
    hooks = []

    # Simple JSON parsing for hook list
    if stdout != "":
        # Strip brackets and split into objects
        items = stdout.replace("[", "").replace("]", "").split("},")
        for item in items:
            item = item.strip()
            if not item:
                continue
            # Extract URL from this item to determine if it matches
            hook_dict = {}
            pairs = item.split(",")
            for pair in pairs:
                if ":" not in pair:
                    continue
                k = pair.split(":")[0].strip().strip('"')
                v = pair.split(":", 1)[1].strip().strip('"')
                if k == "url" or k == "id" or k == "active":
                    if v == "true":
                        v = True
                    elif v == "false":
                        v = False
                    elif v.isdigit() or (v.startswith("-") and v[1:].isdigit()):
                        v = int(v)
                hook_dict[k] = v
            if hook_dict:
                hooks.append(hook_dict)

    # Find matching hook by URL
    hook = None
    for h in hooks:
        if h.get("url") == hook_url:
            hook = h
            break

    state = params.get("state", "present")
    active = params.get("active", True)
    content_type = params.get("content_type", "form")
    events = params.get("events", [])
    secret = params.get("secret")
    insecure_ssl = params.get("insecure_ssl", False)

    # Check mode handling
    if ctx.check_mode:
        if state == "present":
            if hook == None:
                return {"changed": True, "msg": "would create webhook"}
            # Determine if update is needed
            config = hook.get("config", {})
            if (
                config.get("url") != hook_url or
                config.get("content_type") != content_type or
                str(config.get("insecure_ssl")) != ("1" if insecure_ssl else "0") or
                (secret != None and config.get("secret") != secret) or
                hook.get("active") != active or
                sorted(hook.get("events", [])) != sorted(events)
            ):
                return {"changed": True, "msg": "would update webhook"}
            return {"changed": False, "msg": "webhook already exists", "hook_id": hook.get("id")}
        else:  # absent
            if hook != None:
                return {"changed": True, "msg": "would delete webhook"}
            return {"changed": False, "msg": "webhook does not exist"}

    # Real mode logic
    if state == "present":
        # Required events check for present state
        if not events:
            fail("events is required when state=present")

        # Prepare config
        hook_config = {
            "url": hook_url,
            "content_type": content_type,
            "insecure_ssl": "1" if insecure_ssl else "0"
        }
        if secret != None:
            hook_config["secret"] = secret

        data = {}

        if hook == None:
            # Create hook
            payload = {
                "name": "web",
                "config": hook_config,
                "events": events,
                "active": active
            }
            res = github_request("POST", "/repos/" + repo_name + "/hooks", payload)
            if res["skipped"]:
                return {"changed": True, "msg": "would create webhook"}
            
            hook_id = None
            stdout = res["stdout"]
            if '"id":' in stdout:
                idx = stdout.find('"id":')
                rest = stdout[idx + 5:]
                hook_id_str = ""
                for c in rest:
                    if c.isdigit() or (c == '-' and hook_id_str == ''):
                        hook_id_str += c
                    else:
                        break
                if hook_id_str != "":
                    hook_id = int(hook_id_str)
            data = {"hook_id": hook_id} if hook_id != None else {}
            return {"changed": True, "msg": "webhook created", "data": data}
        else:
            # Update hook
            hook_id = hook.get("id")
            payload = {
                "config": hook_config,
                "events": events,
                "active": active
            }
            res = github_request("PATCH", "/repos/" + repo_name + "/hooks/" + str(hook_id), payload)
            if res["skipped"]:
                return {"changed": True, "msg": "would update webhook"}

            return {"changed": True, "msg": "webhook updated", "hook_id": hook_id}

    else:  # absent
        if hook == None:
            return {"changed": False, "msg": "webhook does not exist"}
        else:
            hook_id = hook.get("id")
            res = github_request("DELETE", "/repos/" + repo_name + "/hooks/" + str(hook_id))
            if res["skipped"]:
                return {"changed": True, "msg": "would delete webhook"}
            return {"changed": True, "msg": "webhook deleted", "hook_id": hook_id}
