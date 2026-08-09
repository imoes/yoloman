def main(ctx, params):
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    validate_certs = params.get("validate_certs", False)

    # Validate authentication options
    has_password = api_password != None
    has_token = api_token_id != None and api_token_secret != None

    if not has_password and not has_token:
        fail("one of api_password or api_token_id+api_token_secret is required")

    if has_token:
        if api_token_id == None or api_token_secret == None:
            fail("api_token_id and api_token_secret must be provided together")

    # Build curl command to fetch nodes info
    url = "https://" + api_host + ":8006/api2/json/nodes"

    headers = ["-H", "Accept: application/json"]
    auth_headers = []

    if has_token:
        auth_headers = ["-H", "Authorization: PVEAPIToken=" + api_user + "%" + api_token_id + "=" + api_token_secret]
    else:
        # Build basic auth header manually (no import)
        # Encode as base64: username:password
        auth_str = api_user + ":" + api_password
        encoded = base64_encode(auth_str)
        auth_headers = ["-H", "Authorization: Basic " + encoded]

    # SSL verification handling
    curl_args = ["curl", "-s", "-S"]
    if not validate_certs:
        curl_args.extend(["-k"])

    curl_args.extend(headers + auth_headers + [url])

    res = ctx.run(curl_args)
    if res.rc != 0:
        fail("failed to fetch proxmox nodes: " + res.stderr)

    # Parse JSON manually (no json module available)
    content = res.stdout.strip()
    if not content.startswith("[") or not content.endswith("]"):
        fail("unexpected response format: " + content)

    # Very basic JSON list parsing for the expected structure
    inner = content[1:-1].strip()
    if inner == "":
        nodes = []
    else:
        nodes = []
        depth = 0
        current = ""
        for ch in inner:
            if ch == '{':
                depth += 1
                current += ch
            elif ch == '}':
                depth -= 1
                current += ch
            elif ch == ',' and depth == 0:
                if current.strip():
                    nodes.append(current.strip())
                current = ""
            else:
                current += ch
        if current.strip():
            nodes.append(current.strip())

    # Convert each node dict string to dict representation
    parsed_nodes = []
    for node_str in nodes:
        node_dict = parse_node_dict(node_str)
        if node_dict != None:
            parsed_nodes.append(node_dict)

    return {"changed": False, "msg": "retrieved node information", "data": {"proxmox_nodes": parsed_nodes}}


def base64_encode(input_str):
    # Custom base64 encoding without stdlib
    chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    result = ""
    i = 0
    while i < len(input_str):
        # Get 3 bytes (or pad with zeros)
        b1 = ord(input_str[i])
        i += 1
        b2 = 0
        b3 = 0
        if i < len(input_str):
            b2 = ord(input_str[i])
            i += 1
        if i < len(input_str):
            b3 = ord(input_str[i])
            i += 1

        # Encode 4 chars
        c1 = (b1 >> 2) & 63
        c2 = ((b1 & 3) << 4) | ((b2 >> 4) & 15)
        c3 = ((b2 & 15) << 2) | ((b3 >> 6) & 3)
        c4 = b3 & 63

        result += chars[c1]
        result += chars[c2]
        if i - 2 < len(input_str):
            result += chars[c3]
        else:
            result += "="
        if i - 1 < len(input_str):
            result += chars[c4]
        else:
            result += "="

    return result


def parse_node_dict(s):
    # Parse a JSON object string into a dict
    s = s.strip()
    if not s.startswith("{") or not s.endswith("}"):
        fail("invalid node dict format: " + s)

    content = s[1:-1].strip()
    if content == "":
        return {}

    result = {}
    # Split key:value pairs
    parts = split_json_object(content)
    for part in parts:
        if part == "":
            continue
        # Split at first colon
        colon_idx = part.find(":")
        if colon_idx == -1:
            continue
        key = part[:colon_idx].strip()
        value = part[colon_idx + 1:].strip()
        # Remove quotes from key
        if key.startswith('"') and key.endswith('"'):
            key = key[1:-1]
        # Parse value
        parsed_value = parse_json_value(value)
        result[key] = parsed_value

    return result


def parse_json_value(s):
    s = s.strip()
    if s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    elif s == "true":
        return True
    elif s == "false":
        return False
    elif s == "null" or s == "None":
        return None
    else:
        # Try int conversion without try/except
        if is_integer_string(s):
            return int(s)
        if is_float_string(s):
            return float(s)
        return s


def is_integer_string(s):
    # Check if string looks like an integer
    stripped = s.strip()
    if stripped == "":
        return False
    for i in range(len(stripped)):
        c = stripped[i]
        if i == 0 and c == '-':
            continue
        if c < '0' or c > '9':
            return False
    return True


def is_float_string(s):
    # Check if string looks like a float (basic)
    stripped = s.strip()
    if stripped == "":
        return False
    has_dot = False
    has_e = False
    for i in range(len(stripped)):
        c = stripped[i]
        if i == 0 and (c == '-' or c == '+'):
            continue
        if c == '.' and not has_dot and not has_e:
            has_dot = True
        elif c == 'e' or c == 'E':
            if has_e:
                return False
            has_e = True
            has_dot = False  # reset for exponent part
        elif c < '0' or c > '9':
            return False
    return has_dot or has_e


def split_json_object(s):
    # Split JSON object content by commas while respecting nested braces and quotes
    parts = []
    depth = 0
    in_string = False
    current = ""

    i = 0
    while i < len(s):
        c = s[i]

        if in_string:
            if c == '\\' and i + 1 < len(s):
                current += c + s[i + 1]
                i += 2
                continue
            if c == '"':
                in_string = False
            current += c
        else:
            if c == '"':
                in_string = True
                current += c
            elif c == '{' or c == '[':
                depth += 1
                current += c
            elif c == '}' or c == ']':
                depth -= 1
                current += c
            elif c == ',' and depth == 0:
                parts.append(current.strip())
                current = ""
            else:
                current += c
        i += 1

    if current.strip():
        parts.append(current.strip())

    return parts
