def main(ctx, params):
    token = params["token"]
    name = params["name"]
    state = params.get("state", "present")
    force = params.get("force", True)
    pubkey = params.get("pubkey")

    if state == "present":
        if pubkey == None:
            fail('"pubkey" is required when state=present')
        pubkey_parts = pubkey.split(" ")
        if len(pubkey_parts) < 2:
            fail('"pubkey" parameter has an invalid format')

    # Helper: make GitHub API request
    def github_request(method, path, data=None):
        headers = [
            "Authorization: token " + token,
            "Content-Type: application/json",
            "Accept: application/vnd.github.v3+json",
        ]
        url = "https://api.github.com" + path
        argv = ["curl", "-s", "-X", method]
        for h in headers:
            argv.extend(["-H", h])
        if data != None:
            argv.extend(["-d", data])
        argv.append(url)
        res = ctx.run(argv, mutates=(method != "GET"))
        if res.skipped:
            return None
        if res.rc != 0:
            fail("failed to send GitHub request: " + res.stderr)
        return res

    # Helper: parse a single key dict from JSON string (very basic)
    def parse_key(s):
        d = {}
        s = s.strip()
        # Remove braces
        if s.startswith("{") and s.endswith("}"):
            s = s[1:-1]
        # Split by ", " but be careful with quotes
        items = []
        current = ""
        in_str = False
        for ch in s:
            if ch == '"' and (not current or current[-1] != '\\'):
                in_str = not in_str
                current += ch
            elif ch == ',' and not in_str:
                items.append(current.strip())
                current = ""
            else:
                current += ch
        if current.strip():
            items.append(current.strip())

        for item in items:
            if ':' not in item:
                continue
            key, value = item.split(':', 1)
            key = key.strip().strip('"')
            value = value.strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            elif value.isdigit():
                value = int(value)
            elif value == "true":
                value = True
            elif value == "false":
                value = False
            d[key] = value
        return d

    # Helper: get all keys via pagination
    def get_all_keys():
        url = "/user/keys"
        all_keys = []
        while url:
            res = github_request("GET", url)
            if res == None:
                return None
            data = res.stdout
            keys = []
            if data and data.startswith("[") and data.endswith("]"):
                inner = data.strip()[1:-1]
                # Split top-level objects by '},{'
                parts = []
                depth = 0
                current = ""
                for ch in inner:
                    if ch == '{':
                        depth += 1
                        current += ch
                    elif ch == '}':
                        depth -= 1
                        current += ch
                        if depth == 0:
                            parts.append(current.strip())
                            current = ""
                    else:
                        current += ch
                for p in parts:
                    if p.startswith("{") and p.endswith("}"):
                        keys.append(parse_key(p))
            all_keys.extend(keys)

            # Parse Link header for pagination
            link = ""
            lines = res.stderr.splitlines()
            for line in lines:
                if line.lower().startswith("link:"):
                    link = line[5:].strip()
                    break
            next_url = None
            for part in link.split(","):
                part = part.strip()
                if part.endswith('>; rel="next"'):
                    next_url = part[1:].split('>')[0]
                    break
            url = next_url
        return all_keys

    # Helper: create key
    def create_key():
        payload = '{"title": "' + name + '", "key": "' + pubkey + '"}'
        res = github_request("POST", "/user/keys", payload)
        if res == None:
            return None
        data = res.stdout
        if not data:
            fail("empty response from create_key")
        key = parse_key(data)
        return key

    # Helper: delete keys
    def delete_keys(keys):
        for k in keys:
            key_id = k.get("id")
            if key_id == None:
                continue
            res = github_request("DELETE", "/user/keys/" + str(key_id))
            if res == None:
                return False
            if res.rc != 0:
                fail("failed to delete key " + str(key_id) + ": " + res.stderr)
        return True

    # Get all keys
    all_keys = get_all_keys()
    if all_keys == None:
        fail("failed to fetch GitHub keys")

    if state == "present":
        matching_keys = [k for k in all_keys if k.get("title") == name]
        deleted_keys = []

        # Check for duplicate content under different name
        new_signature = pubkey.split(" ")[1]
        for key in all_keys:
            existing_signature = key.get("key", "").split(" ")[1]
            if new_signature == existing_signature and key.get("title") != name:
                fail("another key with the same content is already registered under the name |" + key.get("title") + "|")

        # If force and existing key differs, delete it
        if matching_keys and force:
            existing_sig = matching_keys[0].get("key", "").split(" ")[1]
            if existing_sig != new_signature:
                delete_keys(matching_keys)
                (deleted_keys, matching_keys) = (matching_keys, [])

        if not matching_keys:
            key = create_key()
            if key == None:
                fail("failed to create key in check mode")
            changed = True
            return {
                "changed": changed,
                "deleted_keys": deleted_keys,
                "matching_keys": [],
                "key": key,
                "msg": "created key " + name
            }
        else:
            return {
                "changed": bool(deleted_keys),
                "deleted_keys": deleted_keys,
                "matching_keys": matching_keys,
                "key": matching_keys[0],
                "msg": "key " + name + " already exists"
            }

    elif state == "absent":
        to_delete = [k for k in all_keys if k.get("title") == name]
        if to_delete:
            if ctx.check_mode:
                return {
                    "changed": True,
                    "deleted_keys": to_delete,
                    "msg": "would delete key " + name
                }
            else:
                delete_keys(to_delete)
                return {
                    "changed": True,
                    "deleted_keys": to_delete,
                    "msg": "deleted key " + name
                }
        else:
            return {
                "changed": False,
                "deleted_keys": [],
                "msg": "key " + name + " not found"
            }

    fail("unsupported state: " + state)
