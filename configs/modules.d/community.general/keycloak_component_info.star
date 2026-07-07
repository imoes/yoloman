def main(ctx, params):
    realm = params["realm"]
    name = params.get("name")
    provider_type = params.get("provider_type")
    parent_id = params.get("parent_id")
    auth_url = params["auth_keycloak_url"]
    auth_client_id = params.get("auth_client_id", "admin-cli")
    auth_client_secret = params.get("auth_client_secret")
    auth_username = params.get("auth_username")
    auth_password = params.get("auth_password")
    auth_realm = params.get("auth_realm", "master")
    token = params.get("token")
    validate_certs = params.get("validate_certs", True)
    connection_timeout = params.get("connection_timeout", 10)
    http_agent = params.get("http_agent", "Ansible")

    # Build auth header
    if token == None:
        if auth_username == None or auth_password == None:
            fail("either 'token' or both 'auth_username' and 'auth_password' must be provided")
        # Get token via password grant
        url = auth_url.rstrip("/") + "/realms/master/protocol/openid-connect/token"
        cmd = [
            "curl",
            "-sS",
            "--max-time",
            str(connection_timeout),
            "-H",
            "Content-Type: application/x-www-form-urlencoded",
            "-H",
            "User-Agent: " + http_agent,
        ]
        if auth_client_secret != None:
            cmd.extend(["--data-urlencode", "client_secret=" + auth_client_secret])
        if auth_realm != None and auth_realm != "":
            cmd.extend(["--data-urlencode", "realm=" + auth_realm])
        cmd.extend([
            "--data-urlencode",
            "client_id=" + auth_client_id,
            "--data-urlencode",
            "grant_type=password",
            "--data-urlencode",
            "username=" + auth_username,
            "--data-urlencode",
            "password=" + auth_password,
            url
        ])
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0:
            fail("failed to retrieve access token: " + res.stderr)
        # Parse JSON manually (no json module)
        token_json = res.stdout.strip()
        start = token_json.find('"access_token":"')
        if start == -1:
            fail("could not parse access_token from token response")
        start += len('"access_token":"')
        end = token_json.find('"', start)
        if end == -1:
            fail("could not parse access_token from token response")
        token = token_json[start:end]

    auth_header = "Bearer " + token

    # Get realm info first (to verify realm exists and get its ID)
    realm_url = auth_url.rstrip("/") + "/admin/realms/" + realm
    curl_realm_args = [
        "curl",
        "-sS",
        "--max-time",
        str(connection_timeout),
        "-H",
        "Authorization: " + auth_header,
        "-H",
        "Content-Type: application/json",
        "-H",
        "User-Agent: " + http_agent,
    ]
    if not validate_certs:
        curl_realm_args.append("-k")
    curl_realm_args.append(realm_url)

    res_realm = ctx.run(curl_realm_args, mutates=False)
    if res_realm.rc != 0:
        fail("failed to retrieve realm '" + realm + "': " + res_realm.stderr)
    if res_realm.stdout.strip() == "":
        fail("realm '" + realm + "' does not exist")

    # Build component query URL
    base_url = auth_url.rstrip("/") + "/admin/realms/" + realm + "/components"
    query_parts = []

    if parent_id != None:
        query_parts.append("parent=" + parent_id)
    else:
        # Default parent is realm itself
        query_parts.append("parent=" + realm)

    if name != None:
        query_parts.append("name=" + name)
    if provider_type != None:
        query_parts.append("type=" + provider_type)

    if query_parts:
        url = base_url + "?" + "&".join(query_parts)
    else:
        url = base_url

    curl_args = [
        "curl",
        "-sS",
        "--max-time",
        str(connection_timeout),
        "-H",
        "Authorization: " + auth_header,
        "-H",
        "Content-Type: application/json",
        "-H",
        "User-Agent: " + http_agent,
    ]
    if not validate_certs:
        curl_args.append("-k")
    curl_args.append(url)

    res = ctx.run(curl_args, mutates=False)
    if res.rc != 0:
        fail("failed to retrieve components: " + res.stderr)

    # Parse JSON manually (no json module)
    output = res.stdout.strip()
    if output == "":
        components = []
    else:
        components = _parse_json_list(output)

    return {"changed": False, "msg": "retrieved components", "data": {"components": components}}


def _parse_json_list(s):
    # Minimal parser for a JSON array of objects, assuming valid JSON
    s = s.strip()
    if not s.startswith("[") or not s.endswith("]"):
        fail("invalid JSON array format")
    inner = s[1:-1].strip()
    if not inner:
        return []

    result = []
    depth = 0
    current = ""
    in_string = False
    escape = False

    for c in inner:
        if escape:
            current += c
            escape = False
            continue
        if c == "\\" and in_string:
            escape = True
            current += c
            continue
        if c == '"' and not escape:
            in_string = not in_string
            current += c
            continue
        if not in_string:
            if c in "{[":
                depth += 1
                current += c
            elif c in "}]":
                depth -= 1
                current += c
            elif c == "," and depth == 0:
                item = current.strip()
                if item:
                    result.append(_parse_json_object(item))
                current = ""
                continue
            else:
                current += c
        else:
            current += c

    last = current.strip()
    if last:
        result.append(_parse_json_object(last))

    return result


def _parse_json_object(s):
    # Return dict representation of object (minimal parser)
    s = s.strip()
    if not s.startswith("{") or not s.endswith("}"):
        fail("invalid JSON object format")

    obj = {}
    inner = s[1:-1].strip()
    if not inner:
        return obj

    in_string = False
    escape = False
    key = ""
    value = ""
    depth = 0
    expecting_value = True

    i = 0
    while i < len(inner):
        c = inner[i]

        if escape:
            if expecting_value:
                key += c
            else:
                value += c
            escape = False
            i += 1
            continue

        if c == "\\" and in_string:
            escape = True
            if expecting_value:
                key += c
            else:
                value += c
            i += 1
            continue

        if c == '"' and not escape:
            in_string = not in_string
            if expecting_value:
                key += c
            else:
                value += c
            i += 1
            continue

        if not in_string:
            if c in "{[":
                depth += 1
                if expecting_value:
                    key += c
                else:
                    value += c
            elif c in "}]":
                depth -= 1
                if expecting_value:
                    key += c
                else:
                    value += c
            elif c == ":" and depth == 0 and expecting_value:
                expecting_value = False
                i += 1
                continue
            elif c == "," and depth == 0 and not expecting_value:
                # Process key-value pair
                obj[_unquote(key.strip())] = _parse_json_value(value.strip())
                key = ""
                value = ""
                expecting_value = True
                i += 1
                continue
            elif c == " " or c == "\t" or c == "\n" or c == "\r":
                if expecting_value:
                    key += c
                else:
                    value += c
            else:
                if expecting_value:
                    key += c
                else:
                    value += c
        else:
            if expecting_value:
                key += c
            else:
                value += c

        i += 1

    # Last pair
    if not expecting_value:
        obj[_unquote(key.strip())] = _parse_json_value(value.strip())

    return obj


def _unquote(s):
    if len(s) >= 2 and s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    return s


def _parse_json_value(s):
    s = s.strip()
    if not s:
        return None
    if s.startswith('"'):
        # Return raw string (including escapes)
        return s
    if s == "true":
        return True
    if s == "false":
        return False
    if s == "null":
        return None
    # Try to parse number
    if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
        return int(s)
    if '.' in s:
        return float(s)
    return s
