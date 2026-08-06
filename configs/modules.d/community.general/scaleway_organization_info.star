def main(ctx, params):
    api_token = params.get("api_token")
    if api_token == None:
        fail("api_token is required")
    
    api_url = params.get("api_url", "https://account.scaleway.com")
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)
    query_parameters = params.get("query_parameters", {})

    # Build URL with query string if parameters provided
    url = api_url.rstrip("/") + "/organizations"
    if len(query_parameters) > 0:
        query_parts = []
        for k in sorted(query_parameters.keys()):
            v = query_parameters[k]
            if v != None:
                query_parts.append(str(k) + "=" + str(v))
        if len(query_parts) > 0:
            url = url + "?" + "&".join(query_parts)

    # Perform the GET request using curl
    headers_list = [
        "X-Auth-Token: " + api_token,
        "Content-Type: application/json"
    ]
    args = ["curl", "-sS", "-G"]
    for h in headers_list:
        args.append("-H")
        args.append(h)
    args.append("-L")
    args.append(url)
    
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        fail("Failed to fetch organizations from Scaleway API: " + res.stderr)

    # Parse JSON manually (no json module)
    # Scaleway API returns {"organizations": [...]}
    raw = res.stdout.strip()
    if not raw.startswith("{") or not raw.endswith("}"):
        fail("Invalid JSON response from Scaleway API")
    
    # Extract the organizations list content
    org_start = raw.find('"organizations"')
    if org_start == -1:
        fail("Missing 'organizations' key in response")
    org_start = raw.find("[", org_start)
    if org_start == -1:
        fail("Missing organizations array in response")
    org_end = raw.rfind("]")
    if org_end == -1 or org_end < org_start:
        fail("Malformed organizations array in response")
    orgs_str = raw[org_start:org_end+1]
    
    # Simple JSON array parser for known-safe structure
    organizations = _parse_json_array(orgs_str)
    return {
        "changed": False,
        "scaleway_organization_info": organizations
    }


def _parse_json_array(s):
    """Parse a simple JSON array string into list of dicts (Starlark representation)."""
    s = s.strip()
    if not (s.startswith("[") and s.endswith("]")):
        fail("Expected JSON array")
    inner = s[1:-1].strip()
    if len(inner) == 0:
        return []
    
    # Split by top-level objects using brace counting
    result = []
    depth = 0
    start = 0
    in_string = False
    i = 0
    while i < len(inner):
        c = inner[i]
        if not in_string:
            if c == '{':
                if depth == 0:
                    start = i
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    obj_str = inner[start:i+1]
                    result.append(_parse_json_object(obj_str))
            elif c == '"' and (i == 0 or inner[i-1] != '\\'):
                in_string = True
            elif c == ',' and depth == 0:
                # Skip commas between objects
                pass
        else:
            if c == '"' and (i == 0 or inner[i-1] != '\\'):
                in_string = False
        i += 1
    
    return result


def _parse_json_object(s):
    """Parse a simple JSON object string into dict."""
    s = s.strip()
    if not (s.startswith("{") and s.endswith("}")):
        fail("Expected JSON object")
    inner = s[1:-1].strip()
    result = {}
    
    # Skip if empty
    if len(inner) == 0:
        return result
    
    # Parse key-value pairs
    i = 0
    while i < len(inner):
        # Skip whitespace and commas
        while i < len(inner) and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == '\n' or inner[i] == ','):
            i += 1
        if i >= len(inner):
            break
        
        # Parse key
        if inner[i] != '"':
            fail("Expected string key")
        i += 1  # skip opening quote
        key_start = i
        while i < len(inner) and (inner[i] != '"' or (i > 0 and inner[i-1] == '\\')):
            i += 1
        if i >= len(inner):
            fail("Unterminated key")
        key = inner[key_start:i]
        i += 1  # skip closing quote
        
        # Skip whitespace
        while i < len(inner) and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == '\n'):
            i += 1
        
        # Expect colon
        if i >= len(inner) or inner[i] != ':':
            fail("Expected ':' after key")
        i += 1
        
        # Skip whitespace
        while i < len(inner) and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == '\n'):
            i += 1
        
        # Parse value
        if i >= len(inner):
            fail("Expected value")
        
        # Handle different value types
        if inner[i] == '"':
            # String value
            i += 1  # skip opening quote
            val_start = i
            while i < len(inner) and (inner[i] != '"' or (i > 0 and inner[i-1] == '\\')):
                i += 1
            if i >= len(inner):
                fail("Unterminated string value")
            value = inner[val_start:i]
            i += 1  # skip closing quote
            result[key] = value
        elif inner[i:i+4] == "true":
            result[key] = True
            i += 4
        elif inner[i:i+5] == "false":
            result[key] = False
            i += 5
        elif inner[i:i+4] == "null":
            result[key] = None
            i += 4
        elif inner[i].isdigit() or inner[i] == '-':
            # Number value
            num_start = i
            if inner[i] == '-':
                i += 1
            while i < len(inner) and (inner[i].isdigit() or inner[i] in ".eE+-"):
                i += 1
            num_str = inner[num_start:i]
            # Try to parse as int or float
            if '.' in num_str or 'e' in num_str.lower() or 'E' in num_str:
                result[key] = float(num_str)
            else:
                result[key] = int(num_str)
        else:
            fail("Unsupported JSON value at position " + str(i) + ": " + inner[i:i+10])
    
    return result
