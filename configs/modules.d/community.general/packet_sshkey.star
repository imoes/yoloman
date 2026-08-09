def main(ctx, params):
    state = params.get("state", "present")
    auth_token = params.get("auth_token")
    if auth_token == None:
        fail("if Packet API token is not in environment variable PACKET_API_TOKEN, the auth_token parameter is required")

    if state not in ["present", "absent"]:
        fail(state + " is not a valid state for this module")

    has_id = "id" in params and params["id"] != None
    has_fingerprint = "fingerprint" in params and params["fingerprint"] != None
    has_key = "key" in params and params["key"] != None
    has_key_file = "key_file" in params and params["key_file"] != None
    has_label = "label" in params and params["label"] != None

    if has_id:
        if has_label or has_fingerprint or has_key or has_key_file:
            fail("id is mutually exclusive with label, fingerprint, key, and key_file")
    if has_fingerprint:
        if has_label or has_key or has_key_file:
            fail("fingerprint is mutually exclusive with label, key, and key_file")
    if has_key:
        if has_key_file:
            fail("key is mutually exclusive with key_file")

    key_value = None
    label_value = None
    if has_key_file:
        key_value = ctx.file_read(params["key_file"]).strip()
        if not has_label:
            parts = key_value.split()
            if len(parts) == 3:
                label_value = parts[2]
            elif len(parts) < 2:
                fail("Public key in key_file is in wrong format")
    if has_key:
        key_value = params["key"].strip()
        if not has_label:
            parts = key_value.split()
            if len(parts) == 3:
                label_value = parts[2]
            elif len(parts) < 2:
                fail("Public key is in wrong format")

    if state == "present":
        if not has_label:
            if label_value == None:
                fail("If you want to ensure a key is present, you must supply both a label and a key string, either in module params, or in a key file. label is missing")
        if key_value == None:
            fail("If you want to ensure a key is present, you must supply both a label and a key string, either in module params, or in a key file. key is missing")
        label = params.get("label") if has_label else label_value

        res = ctx.run(["curl", "-sS", "-X", "GET", "https://api.packet.net/ssh-keys",
                       "-H", "X-Auth-Token: " + auth_token,
                       "-H", "Accept: application/json"])
        if res.rc != 0:
            fail("failed to list SSH keys: " + res.stderr)
        content = res.stdout.strip()
        keys = []
        if content != "" and content.startswith("[") and content.endswith("]"):
            inner = content[1:-1].strip()
            if inner != "":
                objs = []
                depth = 0
                current = ""
                for c in inner:
                    if c == '{':
                        depth += 1
                    elif c == '}':
                        depth -= 1
                    if depth == 0 and c == ',':
                        objs.append(current.strip())
                        current = ""
                    else:
                        current += c
                if current.strip() != "":
                    objs.append(current.strip())

                for obj in objs:
                    obj = obj.strip()
                    if not (obj.startswith("{") and obj.endswith("}")):
                        continue
                    obj_inner = obj[1:-1].strip()
                    item = {}
                    for field in ["id", "key", "label", "fingerprint"]:
                        pattern = '"' + field + '": "'
                        start = obj_inner.find(pattern)
                        if start == -1:
                            continue
                        start += len(pattern)
                        end = obj_inner.find('"', start)
                        if end == -1:
                            continue
                        item[field] = obj_inner[start:end]
                    keys.append(item)

        found = False
        for k in keys:
            if k.get("key") == key_value:
                found = True
                break

        if found:
            return {"changed": False, "msg": "SSH key already exists", "sshkeys": keys}

        if ctx.check_mode:
            return {"changed": True, "msg": "would create SSH key", "sshkeys": [{"label": label, "key": key_value}]}

        escaped_label = label.replace("\\", "\\\\").replace('"', '\\"')
        escaped_key = key_value.replace("\\", "\\\\").replace('"', '\\"')
        res = ctx.run(["curl", "-sS", "-X", "POST", "https://api.packet.net/ssh-keys",
                       "-H", "X-Auth-Token: " + auth_token,
                       "-H", "Content-Type: application/json",
                       "-d", '{"label": "' + escaped_label + '", "key": "' + escaped_key + '"}'])
        if res.rc != 0:
            fail("failed to create SSH key: " + res.stderr)

        content = res.stdout.strip()
        if not (content.startswith("{") and content.endswith("}")):
            fail("unexpected API response: not a JSON object")
        inner = content[1:-1].strip()
        item = {}
        for field in ["id", "key", "label", "fingerprint"]:
            pattern = '"' + field + '": "'
            start = inner.find(pattern)
            if start == -1:
                continue
            start += len(pattern)
            end = inner.find('"', start)
            if end == -1:
                continue
            item[field] = inner[start:end]

        return {"changed": True, "msg": "SSH key created", "sshkeys": [item]}

    else:
        selector_key = None
        if has_id:
            selector_key = ("id", params["id"])
        elif has_fingerprint:
            selector_key = ("fingerprint", params["fingerprint"])
        elif has_key:
            selector_key = ("key", key_value)
        elif has_key_file:
            selector_key = ("key", key_value)
        else:
            fail("for absent state, one of id, fingerprint, key, or key_file must be provided")

        res = ctx.run(["curl", "-sS", "-X", "GET", "https://api.packet.net/ssh-keys",
                       "-H", "X-Auth-Token: " + auth_token,
                       "-H", "Accept: application/json"])
        if res.rc != 0:
            fail("failed to list SSH keys: " + res.stderr)
        content = res.stdout.strip()
        keys = []
        if content != "" and content.startswith("[") and content.endswith("]"):
            inner = content[1:-1].strip()
            if inner != "":
                objs = []
                depth = 0
                current = ""
                for c in inner:
                    if c == '{':
                        depth += 1
                    elif c == '}':
                        depth -= 1
                    if depth == 0 and c == ',':
                        objs.append(current.strip())
                        current = ""
                    else:
                        current += c
                if current.strip() != "":
                    objs.append(current.strip())

                for obj in objs:
                    obj = obj.strip()
                    if not (obj.startswith("{") and obj.endswith("}")):
                        continue
                    obj_inner = obj[1:-1].strip()
                    item = {}
                    for field in ["id", "key", "label", "fingerprint"]:
                        pattern = '"' + field + '": "'
                        start = obj_inner.find(pattern)
                        if start == -1:
                            continue
                        start += len(pattern)
                        end = obj_inner.find('"', start)
                        if end == -1:
                            continue
                        item[field] = obj_inner[start:end]
                    keys.append(item)

        kind, value = selector_key
        matching = []
        for k in keys:
            if kind == "id":
                if k.get("id") == value:
                    matching.append(k)
            elif kind == "fingerprint":
                if k.get("fingerprint") == value:
                    matching.append(k)
            elif kind == "key":
                if k.get("key") == value:
                    matching.append(k)

        if len(matching) == 0:
            return {"changed": False, "msg": "no matching SSH keys found", "sshkeys": []}

        if ctx.check_mode:
            return {"changed": True, "msg": "would delete matching SSH keys", "sshkeys": matching}

        deleted = []
        for k in matching:
            key_id = k.get("id")
            res = ctx.run(["curl", "-sS", "-X", "DELETE", "https://api.packet.net/ssh-keys/" + key_id,
                           "-H", "X-Auth-Token: " + auth_token])
            if res.rc != 0:
                fail("failed to delete SSH key " + key_id + ": " + res.stderr)
            deleted.append(k)

        return {"changed": True, "msg": "SSH key(s) deleted", "sshkeys": deleted}
