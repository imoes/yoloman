def main(ctx, params):
    api_token = params.get("api_token")
    if api_token == None:
        fail("api_token is required")
    
    api_url = params.get("api_url", "https://api.online.net")
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)

    # Build curl command to fetch servers list
    url = api_url + "/api/v1/server"
    curl_args = [
        "curl", "-s", "-G",
        "-H", "Authorization: Bearer " + api_token,
        "-H", "Accept: application/json",
        url
    ]

    # Fetch list of servers (read-only, no mutations)
    servers_res = ctx.run(curl_args, mutates=False)

    if servers_res.rc != 0:
        fail("failed to list servers: " + servers_res.stderr)

    servers_list = servers_res.stdout.strip()
    servers = []

    # Parse JSON manually (simple list of objects)
    if servers_list.startswith("[") and servers_list.endswith("]"):
        inner = servers_list[1:-1].strip()
        if inner != "":
            # Split on },{ while respecting nesting manually (heuristic)
            parts = _split_json_array(inner)
            for part in parts:
                obj = _parse_json_object(part.strip())
                if obj != None:
                    servers.append(obj)

    return {
        "changed": False,
        "msg": "fetched server information",
        "data": {"online_server_info": servers}
    }


def _split_json_array(text):
    # Split array content on },{ while respecting nesting
    parts = []
    depth = 0
    current = []
    for i in range(len(text)):
        ch = text[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
        elif ch == ',' and depth == 0:
            parts.append("".join(current))
            current = []
            continue
        current.append(ch)
    if current:
        parts.append("".join(current))
    return parts


def _parse_json_object(text):
    # Parse a simple JSON object string into a dict
    obj = {}
    text = text.strip()
    if not text.startswith("{") or not text.endswith("}"):
        return None
    inner = text[1:-1].strip()
    if inner == "":
        return obj

    # Split by commas, respecting quoted strings and nesting
    pairs = _split_object_pairs(inner)
    for pair in pairs:
        pair = pair.strip()
        if ":" not in pair:
            continue
        # Split on first colon
        idx = pair.find(":")
        key = pair[:idx].strip().strip('"')
        val_str = pair[idx+1:].strip()

        # Determine value type
        val = _parse_json_value(val_str)
        obj[key] = val

    return obj


def _split_object_pairs(text):
    # Split object content on commas, respecting nesting and quotes
    parts = []
    depth = 0
    in_quotes = False
    current = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == '"' and (i == 0 or text[i-1] != '\\'):
            in_quotes = not in_quotes
            current.append(ch)
        elif ch == '{' and not in_quotes:
            depth += 1
            current.append(ch)
        elif ch == '}' and not in_quotes:
            depth -= 1
            current.append(ch)
        elif ch == ',' and depth == 0 and not in_quotes:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
        i += 1
    if current:
        parts.append("".join(current))
    return parts


def _parse_json_value(val_str):
    val_str = val_str.strip()
    if val_str == "":
        return None
    if val_str == "null":
        return None
    if val_str == "true":
        return True
    if val_str == "false":
        return False
    if val_str.startswith('"') and val_str.endswith('"'):
        return val_str[1:-1]
    # Try integer conversion (no try/except — use find and manual check)
    if _is_integer_string(val_str):
        return int(val_str)
    # Try float conversion
    if _is_float_string(val_str):
        return float(val_str)
    return val_str


def _is_integer_string(s):
    s = s.strip()
    if len(s) == 0:
        return False
    i = 0
    if s[0] == '-' or s[0] == '+':
        i = 1
        if i >= len(s):
            return False
    while i < len(s):
        if s[i] < '0' or s[i] > '9':
            return False
        i += 1
    return True


def _is_float_string(s):
    s = s.strip()
    if len(s) == 0:
        return False
    i = 0
    if s[0] == '-' or s[0] == '+':
        i = 1
    has_dot = False
    has_digit = False
    while i < len(s):
        if s[i] == '.':
            if has_dot:
                return False
            has_dot = True
        elif s[i] >= '0' and s[i] <= '9':
            has_digit = True
        else:
            return False
        i += 1
    return has_dot or has_digit
