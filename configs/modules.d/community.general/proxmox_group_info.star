def main(ctx, params):
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    group = params.get("group")
    validate_certs = params.get("validate_certs", False)

    # Validate authentication method
    if not api_password and (not api_token_id or not api_token_secret):
        fail("either api_password or api_token_id+api_token_secret must be provided")
    if api_token_id and not api_token_secret:
        fail("api_token_id requires api_token_secret")
    if api_token_secret and not api_token_id:
        fail("api_token_secret requires api_token_id")

    base_url = "https://%s/api2/json/access/groups" % api_host
    headers = [
        "-H", "Content-Type: application/x-www-form-urlencoded",
        "-H", "Accept: application/json"
    ]
    auth_args = []

    if api_token_id and api_token_secret:
        auth_args = [
            "-H", "Authorization: PVEAPIToken=%s@pam!%s=%s" % (
                api_user.replace("@", "\\u0040"), api_token_id, api_token_secret
            )
        ]
    else:
        # First get a ticket by authenticating
        auth_res = ctx.run([
            "curl", "-sk", "--max-time", "30",
            "-X", "POST",
            "-d", "username=" + api_user,
            "-d", "password=" + api_password,
            base_url.replace("/groups", "/access/tickets")
        ])
        if auth_res.rc != 0:
            fail("authentication failed: " + auth_res.stderr)
        
        # Extract ticket from response
        ticket = ""
        for line in auth_res.stdout.split("\n"):
            if "ticket=" in line:
                parts = line.strip().split("ticket=")
                if len(parts) >= 2:
                    ticket = parts[1].strip().strip('"')
                    break
        if ticket == "":
            fail("authentication failed: could not extract ticket")
        auth_args = ["-H", "Cookie: PVEAuthCookie=" + ticket]

    # Construct curl command to list groups
    if group != None:
        url = base_url + "/" + group
        res = ctx.run([
            "curl", "-sk", "--max-time", "30"
        ] + headers + auth_args + [url], mutates=False)
    else:
        res = ctx.run([
            "curl", "-sk", "--max-time", "30"
        ] + headers + auth_args + [base_url], mutates=False)

    if res.rc != 0:
        fail("failed to fetch groups: " + res.stderr)

    # Parse JSON manually (no json module available)
    data = _parse_json(res.stdout)

    groups = []
    if group != None:
        # Single group response: data["data"]
        if "data" in data and type(data["data"]) == "dict":
            group_info = data["data"]
            groups.append(_normalize_group(group_info))
    else:
        # List of groups: data["data"] is a list
        if "data" in data and type(data["data"]) == "list":
            for g in data["data"]:
                groups.append(_normalize_group(g))

    return {"changed": False, "msg": "retrieved groups", "data": {"proxmox_groups": groups}}


def _parse_json(s):
    # Minimal JSON parser for known shape: dict with "data" key
    s = s.strip()
    if not s.startswith("{") or not s.endswith("}"):
        fail("invalid JSON: not an object")
    s = s[1:-1]

    # Split top-level key-value pairs
    result = {}
    depth = 0
    current_key = ""
    current_value = ""
    in_string = False
    i = 0
    while i < len(s):
        c = s[i]
        if c == '"' and (i == 0 or s[i - 1] != '\\'):
            in_string = not in_string
        elif not in_string:
            if c in '{[':
                depth += 1
            elif c in '}]':
                depth -= 1
            elif c == ':' and depth == 0:
                _add_key_value(result, current_key, current_value.strip())
                current_value = ""
                i += 1
                continue
            elif c == ',' and depth == 0:
                _add_key_value(result, current_key, current_value.strip())
                current_value = ""
                i += 1
                continue
        current_value += c
        i += 1
    _add_key_value(result, current_key, current_value.strip())

    # Handle nested object values
    for k in list(result.keys()):
        if type(result[k]) == "string":
            val = result[k]
            if val.strip().startswith("{"):
                result[k] = _parse_json(val.strip())
            elif val.strip().startswith("["):
                result[k] = _parse_json_array(val.strip())

    return result


def _add_key_value(d, key, value):
    # Remove quotes and unescape basic sequences
    key = key.strip().strip('"').replace('\\"', '"')
    value = value.strip()
    if value.startswith('"') and value.endswith('"') and len(value) >= 2:
        value = value[1:-1].replace('\\"', '"')
    elif value == "true":
        value = True
    elif value == "false":
        value = False
    elif value.isdigit() or (value.startswith('-') and value[1:].isdigit()):
        value = int(value)
    d[key] = value


def _parse_json_array(s):
    s = s.strip()
    if not s.startswith("[") or not s.endswith("]"):
        fail("invalid JSON array: not an array")
    s = s[1:-1]
    if not s.strip():
        return []

    result = []
    depth = 0
    current = ""
    in_string = False
    i = 0
    while i < len(s):
        c = s[i]
        if c == '"' and (i == 0 or s[i - 1] != '\\'):
            in_string = not in_string
        elif not in_string:
            if c in '{[':
                depth += 1
            elif c in '}]':
                depth -= 1
            elif c == ',' and depth == 0:
                item = current.strip()
                if item.startswith("{"):
                    result.append(_parse_json(item))
                elif item.startswith("["):
                    result.append(_parse_json_array(item))
                elif item.startswith('"') and item.endswith('"'):
                    result.append(item[1:-1].replace('\\"', '"'))
                else:
                    if item == "true":
                        result.append(True)
                    elif item == "false":
                        result.append(False)
                    elif item.isdigit() or (item.startswith('-') and item[1:].isdigit()):
                        result.append(int(item))
                    else:
                        result.append(item)
                current = ""
                i += 1
                continue
        current += c
        i += 1
    item = current.strip()
    if item:
        if item.startswith("{"):
            result.append(_parse_json(item))
        elif item.startswith("["):
            result.append(_parse_json_array(item))
        elif item.startswith('"') and item.endswith('"'):
            result.append(item[1:-1].replace('\\"', '"'))
        else:
            if item == "true":
                result.append(True)
            elif item == "false":
                result.append(False)
            elif item.isdigit() or (item.startswith('-') and item[1:].isdigit()):
                result.append(int(item))
            else:
                result.append(item)

    return result


def _normalize_group(group_data):
    result = {}
    # Map all fields
    for k, v in group_data.items():
        if k == "users" and type(v) == "string":
            # Users field may be a comma-separated string
            result["users"] = v.split(",") if v != "" else []
        elif k == "members":
            # Prefer 'members' over 'users' if present
            if type(v) == "list":
                result["users"] = v
            elif type(v) == "string":
                result["users"] = v.split(",") if v != "" else []
            else:
                result["users"] = []
        else:
            result[k] = v
    return result
