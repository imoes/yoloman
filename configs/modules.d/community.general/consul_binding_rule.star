def main(ctx, params):
    name = params["name"]
    auth_method = params["auth_method"]
    state = params.get("state", "present")
    description = params.get("description")
    selector = params.get("selector")
    bind_type = params.get("bind_type")
    bind_name = params.get("bind_name")
    bind_vars = params.get("bind_vars")

    host = params.get("host", "localhost")
    port = params.get("port", 8500)
    scheme = params.get("scheme", "http")
    token = params.get("token")
    validate_certs = params.get("validate_certs", True)

    # Build base URL
    base_url = scheme + "://" + host + ":" + str(port)
    
    # Build query URL for list operation
    list_url = base_url + "/v1/acl/binding-rules?authmethod=" + auth_method

    # Probe: list existing binding rules for this auth_method
    curl_args = [
        "curl", "-s", "-f", "-L", "-H", "Accept: application/json",
        "-H", "Content-Type: application/json"
    ]
    if token != None and token != "":
        curl_args.extend(["-H", "X-Consul-Token: " + token])
    if not validate_certs:
        curl_args.append("-k")
    curl_args.append(list_url)
    res = ctx.run(curl_args, mutates=False)
    if res.rc != 0:
        fail("failed to list binding rules: " + res.stderr)

    # Parse response: simple JSON list
    existing_list = []
    if res.stdout != "":
        raw = res.stdout.strip()
        if raw.startswith("[") and raw.endswith("]"):
            inner = raw[1:-1].strip()
            if inner == "":
                existing_list = []
            else:
                parts = []
                depth = 0
                current = ""
                for c in inner:
                    if c == '{':
                        depth = depth + 1
                        current = current + c
                    elif c == '}':
                        depth = depth - 1
                        current = current + c
                    elif c == ',' and depth == 0:
                        parts.append(current.strip())
                        current = ""
                    else:
                        current = current + c
                if current.strip() != "":
                    parts.append(current.strip())
                for part in parts:
                    d = {}
                    s = part.strip()
                    if s.startswith("{"):
                        s = s[1:]
                    if s.endswith("}"):
                        s = s[:-1]
                    tokens = []
                    in_str = False
                    tok = ""
                    for ch in s:
                        if ch == '"' and (len(tok) == 0 or tok[-1] != '\\'):
                            in_str = not in_str
                            tok = tok + ch
                        elif ch == ',' and not in_str:
                            tokens.append(tok.strip())
                            tok = ""
                        else:
                            tok = tok + ch
                    if tok.strip() != "":
                        tokens.append(tok.strip())
                    for t in tokens:
                        kv = t.split(":", 1)
                        if len(kv) == 2:
                            k = kv[0].strip().strip('"')
                            v = kv[1].strip()
                            if v.startswith('"') and v.endswith('"'):
                                v = v[1:-1]
                            elif v == "true":
                                v = True
                            elif v == "false":
                                v = False
                            elif v.isdigit():
                                v = int(v)
                            d[k] = v
                    existing_list.append(d)

    # Find matching rule by description prefix
    existing = None
    prefix = name + ": "
    for rule in existing_list:
        if type(rule) == "dict" and type(rule.get("Description")) == "string":
            if rule.get("Description").startswith(prefix):
                existing = rule
                break

    # Handle absent state
    if state == "absent":
        if existing == None:
            return {"changed": False, "msg": "binding rule not present", "binding_rule": {}}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete binding rule", "binding_rule": existing}

        delete_url = base_url + "/v1/acl/binding-rule/" + existing["ID"]
        res = ctx.run(
            ["curl", "-s", "-f", "-X", "DELETE", "-H", "Accept: application/json",
             "-H", "Content-Type: application/json"] +
            (["-H", "X-Consul-Token: " + token] if token else []) +
            (["-k"] if not validate_certs else []) +
            [delete_url],
            mutates=True,
        )
        if res.skipped:
            return {"changed": True, "msg": "would delete binding rule", "binding_rule": existing}
        if res.rc != 0:
            fail("failed to delete binding rule: " + res.stderr)

        return {"changed": True, "msg": "deleted binding rule", "binding_rule": existing}

    # state == "present"
    # Prepare object payload
    payload = {}
    desc_text = description if description != None else ""
    payload["Description"] = name + ": " + desc_text
    payload["AuthMethod"] = auth_method

    if selector != None:
        payload["Selector"] = selector
    if bind_type != None:
        payload["BindType"] = bind_type
    if bind_name != None:
        payload["BindName"] = bind_name
    if bind_vars != None:
        payload["BindVars"] = bind_vars

    # Determine operation type
    is_update = existing != None

    # In check_mode without change: no change
    if ctx.check_mode and not is_update:
        return {"changed": True, "msg": "would create binding rule", "binding_rule": payload}
    if ctx.check_mode and is_update:
        # Rough diff: compare payload keys excluding operational fields
        def clean(r):
            return {k: v for k, v in r.items() if k not in ["CreateIndex", "ModifyIndex", "ID"]}
        equal = True
        if len(clean(payload)) != len(clean(existing)):
            equal = False
        else:
            for k in clean(payload):
                if not k in clean(existing) or clean(payload)[k] != clean(existing)[k]:
                    equal = False
                    break
        if equal:
            return {"changed": False, "msg": "binding rule already present", "binding_rule": existing}
        return {"changed": True, "msg": "would update binding rule", "binding_rule": payload}

    # Perform the actual operation
    if is_update:
        # Update
        update_url = base_url + "/v1/acl/binding-rule/" + existing["ID"]
        json_str = serialize_json(payload)
        res = ctx.run(
            ["curl", "-s", "-f", "-X", "PUT", "-H", "Accept: application/json",
             "-H", "Content-Type: application/json"] +
            (["-H", "X-Consul-Token: " + token] if token else []) +
            (["-k"] if not validate_certs else []) +
            ["--data", json_str] +
            [update_url],
            mutates=True,
        )
        if res.skipped:
            return {"changed": True, "msg": "would update binding rule", "binding_rule": payload}
        if res.rc != 0:
            fail("failed to update binding rule: " + res.stderr)
        created = parse_simple_json_object(res.stdout)
        return {"changed": True, "msg": "updated binding rule", "binding_rule": created}

    else:
        # Create
        create_url = base_url + "/v1/acl/binding-rule"
        json_str = serialize_json(payload)
        res = ctx.run(
            ["curl", "-s", "-f", "-X", "PUT", "-H", "Accept: application/json",
             "-H", "Content-Type: application/json"] +
            (["-H", "X-Consul-Token: " + token] if token else []) +
            (["-k"] if not validate_certs else []) +
            ["--data", json_str] +
            [create_url],
            mutates=True,
        )
        if res.skipped:
            return {"changed": True, "msg": "would create binding rule", "binding_rule": payload}
        if res.rc != 0:
            fail("failed to create binding rule: " + res.stderr)
        created = parse_simple_json_object(res.stdout)
        return {"changed": True, "msg": "created binding rule", "binding_rule": created}


def serialize_json(obj):
    if type(obj) == "dict":
        parts = []
        for k, v in obj.items():
            val_str = ""
            if type(v) == "bool":
                val_str = "true" if v else "false"
            elif type(v) == "string":
                val_str = '"' + v + '"'
            elif type(v) == "dict":
                val_str = serialize_json(v)
            else:
                val_str = str(v)
            parts.append('"' + k + '":' + val_str)
        return "{" + ",".join(parts) + "}"
    elif type(obj) == "bool":
        return "true" if obj else "false"
    elif type(obj) == "string":
        return '"' + obj + '"'
    else:
        return str(obj)


def parse_simple_json_object(s):
    s = s.strip()
    if not (s.startswith("{") and s.endswith("}")):
        return {}
    inner = s[1:-1].strip()
    if inner == "":
        return {}
    result = {}
    tokens = []
    in_str = False
    tok = ""
    depth = 0
    for ch in inner:
        if ch == '"' and (len(tok) == 0 or tok[-1] != '\\'):
            in_str = not in_str
            tok = tok + ch
        elif ch == '{' and not in_str:
            depth = depth + 1
            tok = tok + ch
        elif ch == '}' and not in_str:
            depth = depth - 1
            tok = tok + ch
        elif ch == ',' and not in_str and depth == 0:
            tokens.append(tok.strip())
            tok = ""
        else:
            tok = tok + ch
    if tok.strip() != "":
        tokens.append(tok.strip())
    for t in tokens:
        kv = t.split(":", 1)
        if len(kv) == 2:
            k = kv[0].strip().strip('"')
            v = kv[1].strip()
            # Handle nested objects
            if v.startswith("{") and v.endswith("}"):
                v = parse_simple_json_object(v)
            elif v.startswith('"') and v.endswith('"'):
                v = v[1:-1]
            elif v == "true":
                v = True
            elif v == "false":
                v = False
            elif v.isdigit():
                v = int(v)
            result[k] = v
    return result
