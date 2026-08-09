def main(ctx, params):
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    domain = params.get("domain")
    user = params.get("user")
    userid_param = params.get("userid")
    validate_certs = params.get("validate_certs", False)

    if api_password == None and api_token_id == None:
        fail("one of api_password or api_token_id is required")
    if api_token_id != None and api_token_secret == None:
        fail("api_token_secret is required when using api_token_id")
    if api_token_id == None and api_token_secret != None:
        fail("api_token_id is required when using api_token_secret")

    # Validate mutual exclusivity of (user, userid) and (domain, userid)
    if user != None and userid_param != None:
        fail("user and userid are mutually exclusive")
    if domain != None and userid_param != None:
        fail("domain and userid are mutually exclusive")

    # Construct full userid if user + domain provided
    if user != None and domain != None:
        full_userid = user + "@" + domain
    else:
        full_userid = userid_param

    # Build curl command to list users via Proxmox API
    headers = [
        "-H", "Accept: application/json"
    ]

    # Authentication: token or password
    if api_token_id != None:
        auth_header = "Authorization: PVEAPIToken=" + api_user + "=" + api_token_secret
        headers.extend(["-H", auth_header])
    else:
        # Use basic auth; note: in real scenario you'd get session cookie first,
        # but for info modules we assume api_password is already a valid ticket
        # or we fail. In practice, this module expects token-based auth mostly.
        fail("password-based authentication not supported in this Starlark implementation; use api_token_id/api_token_secret")

    url = "https://" + api_host + ":8006/api2/json/access/users"

    # Build query parameters for filtering
    query_parts = []
    if full_userid != None:
        url = url + "/" + full_userid
    else:
        if domain != None:
            # API accepts ?realm=<domain> but full=1 is always used
            query_parts.append("realm=" + domain)
        query_parts.append("full=1")

    if query_parts:
        url = url + "?" + "&".join(query_parts)

    # Build curl args
    curl_args = ["curl", "-s", "-S"]
    if not validate_certs:
        curl_args.append("-k")
    for h in headers:
        curl_args.append(h)
    curl_args.append(url)

    # Run the probe
    res = ctx.run(curl_args)
    if res.rc != 0:
        if full_userid != None:
            fail("failed to retrieve user '" + full_userid + "': " + res.stderr)
        else:
            fail("failed to list users: " + res.stderr)

    # Parse JSON manually (no json module)
    stdout = res.stdout
    # Strip whitespace
    stdout = stdout.strip()
    # Handle single user vs list
    # API returns either a dict with "data" key for list, or a dict directly for single user
    # For simplicity, we detect based on outer structure
    if stdout.startswith("{"):
        # Try to determine if it's a list response or single user
        # Heuristic: look for "data" top-level key
        if '"data":[' in stdout or '"data": [' in stdout:
            # List response
            # Extract content after '"data":[' and before last ']'
            start = stdout.find('"data":[')
            if start == -1:
                fail("unexpected JSON structure: missing 'data' array")
            start += len('"data":[')
            # Find matching close bracket; simple count
            depth = 0
            end = start
            for i in range(start, len(stdout)):
                if stdout[i] == '[':
                    depth += 1
                elif stdout[i] == ']':
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
            data_part = stdout[start:end].strip()
            if data_part == "":
                users_json = []
            else:
                # Split JSON objects (naive approach: by '},{')
                # Replace escaped quotes to avoid issues
                data_part = data_part.replace('\\"', '"')
                # Try splitting on },{ pattern
                users_json = []
                current = ""
                brace_depth = 0
                for ch in data_part:
                    if ch == '{':
                        brace_depth += 1
                    elif ch == '}':
                        brace_depth -= 1
                    if ch == ',' and brace_depth == 0:
                        if current.strip():
                            users_json.append(current.strip())
                        current = ""
                    else:
                        current += ch
                if current.strip():
                    users_json.append(current.strip())
        else:
            # Single user response
            users_json = [stdout.strip()]
    else:
        fail("unexpected JSON format")

    # Parse each user dict
    parsed_users = []
    for u in users_json:
        user_dict = {}
        # Parse fields manually — only common ones needed per RETURN spec
        # Extract key: value pairs (no nested arrays/objects beyond tokens)
        # This is a simplified parser; full support requires more robustness
        # but per constraints, keep it lean
        u = u.strip()
        if u.startswith("{") and u.endswith("}"):
            u = u[1:-1]

        # Split on commas not inside quotes or braces
        parts = split_json_fields(u)

        for part in parts:
            part = part.strip()
            if part == "":
                continue
            # Split key/value on first colon
            idx = part.find(":")
            if idx == -1:
                continue
            key_raw = part[:idx].strip()
            val_raw = part[idx+1:].strip()
            # Remove quotes from key
            if key_raw.startswith('"') and key_raw.endswith('"'):
                key = key_raw[1:-1]
            else:
                continue

            # Handle value types
            if val_raw.startswith('"') and val_raw.endswith('"'):
                val = val_raw[1:-1]
            elif val_raw == "true":
                val = True
            elif val_raw == "false":
                val = False
            elif val_raw.isdigit() or (val_raw.startswith('-') and val_raw[1:].isdigit()):
                val = int(val_raw)
            else:
                val = val_raw

            # Normalize key names
            if key == "enable":
                key = "enabled"
                val = bool(val)
            elif key == "userid":
                # Split into user and domain
                if "@" in str(val):
                    parts = str(val).split("@", 1)
                    user_dict["user"] = parts[0]
                    user_dict["domain"] = parts[1]
                user_dict[key] = val
            elif key == "groups":
                if val == "":
                    val = []
                elif isinstance(val, str) and val != "":
                    val = val.split(",")
            elif key == "tokens":
                # Expect tokens as dict; parse nested
                # Since raw value is dict string like { "token1": { ... } }
                val = parse_tokens(val_raw)

            user_dict[key] = val

        parsed_users.append(user_dict)

    return {"changed": False, "msg": "retrieved user information", "data": {"proxmox_users": parsed_users}}


def split_json_fields(json_str):
    parts = []
    current = ""
    in_quotes = False
    brace_depth = 0
    i = 0
    while i < len(json_str):
        ch = json_str[i]
        if ch == '"' and (i == 0 or json_str[i-1] != '\\'):
            in_quotes = not in_quotes
            current += ch
        elif not in_quotes:
            if ch == '{':
                brace_depth += 1
            elif ch == '}':
                brace_depth -= 1
            elif ch == ',' and brace_depth == 0:
                if current.strip():
                    parts.append(current.strip())
                current = ""
                i += 1
                continue
            current += ch
        else:
            current += ch
        i += 1
    if current.strip():
        parts.append(current.strip())
    return parts


def parse_tokens(tokens_str):
    # tokens_str is a JSON dict like: { "token1": { ... }, "token2": {...} }
    tokens_str = tokens_str.strip()
    if not (tokens_str.startswith("{") and tokens_str.endswith("}")):
        return []
    tokens_str = tokens_str[1:-1].strip()
    if tokens_str == "":
        return []
    # Split top-level keys: key: {...}
    result = []
    # Simple approach: find tokenid (quoted) and its associated {...}
    # This is a basic implementation — sufficient for typical Proxmox responses
    while tokens_str:
        tokens_str = tokens_str.strip()
        if not tokens_str.startswith('"'):
            break
        # Extract tokenid
        end_quote = tokens_str.find('"', 1)
        if end_quote == -1:
            break
        tokenid = tokens_str[1:end_quote]
        tokens_str = tokens_str[end_quote+1:].strip()
        if not tokens_str.startswith(":"):
            break
        tokens_str = tokens_str[1:].strip()
        # Expect '{'
        if not tokens_str.startswith('{'):
            break
        # Find matching }
        depth = 0
        j = 0
        for j, ch in enumerate(tokens_str):
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    break
        token_json = tokens_str[:j+1]
        tokens_str = tokens_str[j+1:].strip()
        if tokens_str.startswith(','):
            tokens_str = tokens_str[1:]

        # Parse token object manually
        token_obj = parse_token_obj(token_json, tokenid)
        if token_obj:
            result.append(token_obj)

    return result


def parse_token_obj(token_json, tokenid):
    obj = {}
    # Remove braces
    inner = token_json[1:-1].strip()
    if inner == "":
        return obj
    # Split fields
    fields = split_json_fields(inner)
    for f in fields:
        f = f.strip()
        if not f:
            continue
        idx = f.find(":")
        if idx == -1:
            continue
        k_raw = f[:idx].strip()
        v_raw = f[idx+1:].strip()
        if k_raw.startswith('"') and k_raw.endswith('"'):
            k = k_raw[1:-1]
        else:
            continue
        if v_raw.startswith('"') and v_raw.endswith('"'):
            v = v_raw[1:-1]
        elif v_raw == "true":
            v = True
        elif v_raw == "false":
            v = False
        elif v_raw.isdigit():
            v = int(v_raw)
        else:
            v = v_raw

        if k == "privsep":
            obj[k] = bool(v)
        else:
            obj[k] = v

    obj["tokenid"] = tokenid
    return obj
