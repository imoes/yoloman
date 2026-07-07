def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    auth_type = params.get("type")
    description = params.get("description")
    display_name = params.get("display_name")
    max_token_ttl = params.get("max_token_ttl")
    token_locality = params.get("token_locality")
    config = params.get("config")
    host = params.get("host", "localhost")
    port = params.get("port", 8500)
    scheme = params.get("scheme", "http")
    token = params.get("token")
    validate_certs = params.get("validate_certs", True)
    ca_path = params.get("ca_path")

    # Validate required params
    if state == "present":
        if auth_type == None:
            fail("type is required when state is present")
        if config == None:
            fail("config is required when state is present")

    # Build base URL
    base_url = "%s://%s:%d" % (scheme, host, port)

    # Build request headers
    headers = {"Content-Type": "application/json"}
    if token != None:
        headers["X-Consul-Token"] = token

    # Build curl args for GET
    curl_args = [
        "curl", "-s", "-X", "GET",
        "%s/v1/acl/auth-method/%s" % (base_url, name)
    ]
    if not validate_certs:
        curl_args.append("-k")
    if ca_path != None:
        curl_args.extend(["--cacert", ca_path])

    # Probe current state
    res = ctx.run(curl_args, mutates=False)
    if res.rc == 0:
        # Parse JSON manually using simple str methods
        lines = res.stdout.splitlines()
        if len(lines) == 0:
            fail("empty response from consul")
        # Assume single-line JSON; common for simple responses
        raw_json = res.stdout.strip()
        current = _parse_json(raw_json)
        exists = True
    elif res.rc == 404:
        current = None
        exists = False
    else:
        fail("failed to get auth method: " + res.stderr)

    if state == "absent":
        if exists:
            # Delete the auth method
            delete_args = [
                "curl", "-s", "-X", "DELETE",
                "%s/v1/acl/auth-method/%s" % (base_url, name),
                "-w", "%{http_code}",
                "-o", "/dev/null"
            ]
            if not validate_certs:
                delete_args.append("-k")
            if ca_path != None:
                delete_args.extend(["--cacert", ca_path])
            if token != None:
                delete_args.extend(["-H", "X-Consul-Token:" + token])

            if ctx.check_mode:
                return {"changed": True, "msg": "would delete auth method " + name}
            res_del = ctx.run(delete_args, mutates=True)
            if res_del.rc != 0:
                fail("failed to delete auth method " + name + ": " + res_del.stderr)
            return {"changed": True, "msg": "deleted auth method " + name}
        else:
            return {"changed": False, "msg": "auth method " + name + " already absent"}

    # State == "present"
    if exists:
        # Build new object
        new_obj = {
            "Name": name,
            "Type": auth_type,
            "Config": config,
            "Description": description,
            "DisplayName": display_name,
            "MaxTokenTTL": max_token_ttl,
            "TokenLocality": token_locality,
        }
        cleaned_new_obj = {}
        for k in new_obj:
            if new_obj[k] != None:
                cleaned_new_obj[k] = new_obj[k]

        # Normalize TTL
        if max_token_ttl != None:
            ttl_seconds = _parse_ttl_to_seconds(max_token_ttl)
            normalized_ttl = _format_ttl_from_seconds(ttl_seconds)
            cleaned_new_obj["MaxTokenTTL"] = normalized_ttl

        # Simple field comparison
        needs_update = False
        for key in cleaned_new_obj:
            if key not in current or current[key] != cleaned_new_obj[key]:
                needs_update = True
                break

        if not needs_update:
            return {"changed": False, "msg": "auth method %s already present and correct" % name}

        # Perform update
        update_body = _serialize_json(cleaned_new_obj)
        update_args = [
            "curl", "-s", "-X", "PUT",
            "%s/v1/acl/auth-method/%s" % (base_url, name),
            "-d", update_body,
            "-w", "%{http_code}",
            "-o", "/dev/null"
        ]
        if not validate_certs:
            update_args.append("-k")
        if ca_path != None:
            update_args.extend(["--cacert", ca_path])
        if token != None:
            update_args.extend(["-H", "X-Consul-Token:" + token])

        if ctx.check_mode:
            return {"changed": True, "msg": "would update auth method " + name}
        res_upd = ctx.run(update_args, mutates=True)
        if res_upd.rc != 0:
            fail("failed to update auth method " + name + ": " + res_upd.stderr)
        return {"changed": True, "msg": "updated auth method " + name, "data": {"auth_method": current}}

    # Create new auth method
    new_obj = {
        "Name": name,
        "Type": auth_type,
        "Config": config,
        "Description": description,
        "DisplayName": display_name,
        "MaxTokenTTL": max_token_ttl,
        "TokenLocality": token_locality,
    }
    cleaned_new_obj = {}
    for k in new_obj:
        if new_obj[k] != None:
            cleaned_new_obj[k] = new_obj[k]

    # Normalize TTL
    if max_token_ttl != None:
        ttl_seconds = _parse_ttl_to_seconds(max_token_ttl)
        normalized_ttl = _format_ttl_from_seconds(ttl_seconds)
        cleaned_new_obj["MaxTokenTTL"] = normalized_ttl

    create_body = _serialize_json(cleaned_new_obj)
    create_args = [
        "curl", "-s", "-X", "PUT",
        "%s/v1/acl/auth-method" % base_url,
        "-d", create_body,
        "-w", "%{http_code}",
        "-o", "/dev/null"
    ]
    if not validate_certs:
        create_args.append("-k")
    if ca_path != None:
        create_args.extend(["--cacert", ca_path])
    if token != None:
        create_args.extend(["-H", "X-Consul-Token:" + token])

    if ctx.check_mode:
        return {"changed": True, "msg": "would create auth method " + name}
    res_create = ctx.run(create_args, mutates=True)
    if res_create.rc != 0:
        fail("failed to create auth method " + name + ": " + res_create.stderr)

    return {
        "changed": True,
        "msg": "created auth method " + name,
        "data": {"auth_method": cleaned_new_obj}
    }


def _parse_ttl_to_seconds(ttl_str):
    ttl_seconds = 0
    parts = ttl_str.split()
    for part in parts:
        part = part.strip()
        if part.endswith("s") and not part.endswith("ms"):
            ttl_seconds += int(part[:-1])
        elif part.endswith("m"):
            ttl_seconds += int(part[:-1]) * 60
        elif part.endswith("h"):
            ttl_seconds += int(part[:-1]) * 3600
    return ttl_seconds


def _format_ttl_from_seconds(ttl_seconds):
    if ttl_seconds == 0:
        return "0s"
    normalized = ""
    h = ttl_seconds // 3600
    if h > 0:
        normalized += "%dh" % h
        ttl_seconds %= 3600
    m = ttl_seconds // 60
    if m > 0:
        normalized += "%dm" % m
        ttl_seconds %= 60
    if ttl_seconds > 0:
        normalized += "%ds" % ttl_seconds
    return normalized


def _parse_json(json_str):
    # Very minimal parser for known top-level keys; only supports strings and simple dicts
    # Not production-grade; assumes Consul returns valid, flat JSON
    result = {}
    json_str = json_str.strip()
    if json_str == "{}":
        return result
    # Remove outer braces
    inner = json_str[1:-1].strip()
    if inner == "":
        return result

    # Simple key-value split (assumes keys like "Name", "Type", etc.)
    # Handle quotes manually
    i = 0
    while i < len(inner):
        # Skip whitespace
        while i < len(inner) and inner[i] in " \t\n\r,":
            i += 1
        if i >= len(inner):
            break

        # Expect "key"
        if inner[i] != '"':
            # Skip unknown tokens
            i += 1
            continue
        key_start = i + 1
        i = inner.find('"', key_start)
        if i == -1:
            break
        key = inner[key_start:i]
        i += 1

        # Skip colon and whitespace
        while i < len(inner) and inner[i] in " \t\n\r:":
            i += 1

        # Expect value: string or object
        if i < len(inner) and inner[i] == '"':
            # String value
            i += 1
            val_start = i
            # Simple escape handling (skip escaped quotes)
            while i < len(inner):
                if inner[i] == '\\' and i + 1 < len(inner) and inner[i+1] == '"':
                    i += 2
                    continue
                if inner[i] == '"':
                    break
                i += 1
            val = inner[val_start:i]
            i += 1
            result[key] = val
        elif i < len(inner) and inner[i] == '{':
            # Object value (nested parsing is hard; just capture literal JSON)
            depth = 1
            val_start = i
            i += 1
            while i < len(inner) and depth > 0:
                if inner[i] == '{':
                    depth += 1
                elif inner[i] == '}':
                    depth -= 1
                i += 1
            val = inner[val_start:i]
            result[key] = val
        else:
            # Skip unknown values
            while i < len(inner) and inner[i] not in ',}':
                i += 1

    return result


def _serialize_json(obj):
    # Minimal JSON serializer for known structure
    items = []
    for k in obj:
        v = obj[k]
        kv = '"%s": %s' % (k, _json_value(v))
        items.append(kv)
    return "{" + ", ".join(items) + "}"


def _json_value(v):
    if type(v) == "string":
        # Escape special chars minimally
        escaped = v.replace("\\", "\\\\").replace('"', '\\"')
        return '"%s"' % escaped
    elif type(v) == "dict":
        return _serialize_json(v)
    elif type(v) == "bool":
        return "true" if v else "false"
    elif type(v) == "int":
        return str(v)
    else:
        # Fallback: assume string
        return '"%s"' % str(v)
