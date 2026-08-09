def main(ctx, params):
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    domain = params.get("domain")
    validate_certs = params.get("validate_certs", False)

    # Validate token parameters
    if api_token_id != None and api_token_secret == None:
        fail("api_token_secret is required when api_token_id is provided")
    if api_token_id == None and api_password == None:
        fail("Either api_password or api_token_id must be provided")

    # Build authentication header (simple Bearer or password-based)
    if api_token_id != None:
        auth_header = "PVEAPIToken=" + api_user + "!" + api_token_id + "=" + api_token_secret
    else:
        auth_header = "PVEAuthCookie=" + api_password  # Note: in practice this would need full auth flow, but simplified for info module

    # Construct API URL
    url = "https://%s/api2/json/access/domains" % api_host
    if domain != None:
        url = "https://%s/api2/json/access/domains/%s" % (api_host, domain)

    # Prepare headers
    headers = [
        "Authorization: " + auth_header,
        "Accept: application/json"
    ]

    # Perform GET request (read-only, no mutation)
    res = ctx.run([
        "curl",
        "-s", "-k" if not validate_certs else "",
        "-H", "Content-Type: application/x-www-form-urlencoded",
        "-H", headers[0],
        "-H", headers[1] if len(headers) > 1 else "",
        url
    ], mutates=False)

    # Handle curl exit
    if res.rc != 0:
        fail("Failed to fetch domains from Proxmox: " + res.stderr)

    # Parse JSON response manually (simple approach)
    # Proxmox returns JSON like: {"data": [...]} or single object if domain specified
    stdout = res.stdout.strip()
    if not stdout:
        fail("Empty response from Proxmox API")

    # Basic JSON extraction for 'data' key (handles list or object)
    if stdout.startswith('{"data":'):
        # Extract list after "data":
        idx = stdout.find('"data":')
        if idx == -1:
            fail("Invalid JSON response from Proxmox")
        data_str = stdout[idx + len('"data":'):]
        # Remove trailing } if present
        if data_str.endswith('}'):
            data_str = data_str[:-1].strip()
        if data_str.startswith('['):
            # Parse as list
            domains = _parse_json_array(data_str)
        else:
            # Single object — wrap in list
            domains = [_parse_json_object(data_str)]
    elif stdout.startswith('{'):
        # Single object (e.g., when domain specified)
        domains = [_parse_json_object(stdout)]
    else:
        fail("Unexpected JSON format from Proxmox")

    return {"changed": False, "msg": "Retrieved domain information", "data": {"proxmox_domains": domains}}


def _parse_json_object(json_str):
    # Very basic object parser for JSON without external deps
    result = {}
    # Skip outer braces
    json_str = json_str.strip()
    if not json_str.startswith('{') or not json_str.endswith('}'):
        fail("Malformed JSON object")
    json_str = json_str[1:-1].strip()
    if not json_str:
        return result

    # Split by comma, ignoring commas in strings (naive but sufficient for simple domains response)
    parts = []
    depth = 0
    current = ""
    in_str = False
    for c in json_str:
        if c == '"' and (not current or current[-1] != '\\'):
            in_str = not in_str
            current += c
        elif not in_str:
            if c == '{' or c == '[':
                depth += 1
            elif c == '}' or c == ']':
                depth -= 1
            elif c == ',' and depth == 0:
                parts.append(current.strip())
                current = ""
                continue
        current += c
    if current.strip():
        parts.append(current.strip())

    for part in parts:
        # Split key-value by first colon
        eq_idx = part.find(':')
        if eq_idx == -1:
            continue
        key = part[:eq_idx].strip()
        val = part[eq_idx + 1:].strip()

        # Remove quotes from key
        if key.startswith('"') and key.endswith('"'):
            key = key[1:-1]

        # Parse value
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        elif val == "true":
            val = True
        elif val == "false":
            val = False
        elif val.isdigit() or (val.startswith('-') and val[1:].isdigit()):
            val = int(val)
        # Note: floats not expected in this specific API

        result[key] = val

    return result


def _parse_json_array(json_str):
    # Very basic array parser; assumes top-level list like [ ... ]
    if not (json_str.startswith('[') and json_str.endswith(']')):
        fail("Malformed JSON array")
    content = json_str[1:-1].strip()
    if not content:
        return []

    items = []
    depth = 0
    current = ""
    in_str = False

    for c in content:
        if c == '"' and (not current or current[-1] != '\\'):
            in_str = not in_str
            current += c
        elif not in_str:
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
            elif c == '[':
                depth += 1
            elif c == ']':
                depth -= 1
            elif c == ',' and depth == 0:
                item = current.strip()
                if item:
                    items.append(_parse_json_object(item))
                current = ""
                continue
        current += c

    if current.strip():
        items.append(_parse_json_object(current.strip()))

    return items
