def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)
    headers = params.get("headers", {})

    # Build URL
    url = "%s://%s:%d/api/objects/ca/host_key_cert/%s" % (
        utm_protocol, utm_host, utm_port, name
    )

    # Build headers
    req_headers = {"X-Auth-Token": utm_token, "Content-Type": "application/json"}
    for k, v in headers.items():
        req_headers[k] = v

    # Probe current state (read-only)
    curl_args = ["curl", "-s", "-X", "GET", url, "-H", "accept: application/json"]
    if not validate_certs:
        curl_args.append("-k")

    res = ctx.run(curl_args, mutates=False)

    if res.rc == 0:
        # Found entry — parse JSON manually (no json module)
        content = res.stdout
        if not content:
            fail("Empty response from server")

        # Simple JSON parsing for known keys (RFC 8259 compliant subset)
        obj = _parse_json_dict(content)
        if obj == None:
            fail("Failed to parse JSON response")

        # Return current info for state == "present" or "absent" (info module)
        return {"changed": False, "msg": "found ca host_key_cert " + name, "data": {"result": obj}}
    elif res.rc == 22:  # 404 -> not found (curl returns rc 22 for HTTP 404)
        if state == "absent":
            return {"changed": False, "msg": "ca host_key_cert " + name + " not found, nothing to do"}
        else:
            fail("ca host_key_cert " + name + " not found and state=present is not supported by this info module")
    else:
        fail("failed to query ca host_key_cert " + name + ": " + res.stderr)

# --- Helper: simple JSON dict parser for known keys (no library available) ---
def _parse_json_dict(s):
    s = s.strip()
    if not s.startswith("{") or not s.endswith("}"):
        return None

    result = {}
    inner = s[1:-1].strip()
    if not inner:
        return result

    # Split top-level key-value pairs
    pairs = _split_json_pairs(inner)
    for pair in pairs:
        eq = pair.find(":")
        if eq == -1:
            return None
        key_part = pair[:eq].strip()
        val_part = pair[eq+1:].strip()

        key = _parse_json_string(key_part)
        if key == None:
            return None

        val = _parse_json_value(val_part)
        if val == None:
            return None

        result[key] = val

    return result

def _split_json_pairs(s):
    result = []
    depth = 0
    in_str = False
    current = []
    i = 0
    while i < len(s):
        c = s[i]
        if in_str:
            if c == "\\" and i+1 < len(s):
                current.append(c)
                current.append(s[i+1])
                i += 2
                continue
            elif c == "\"":
                in_str = False
            current.append(c)
        else:
            if c == "\"":
                in_str = True
                current.append(c)
            elif c in "{[":
                depth += 1
                current.append(c)
            elif c in "}]":
                depth -= 1
                current.append(c)
            elif c == "," and depth == 0:
                result.append("".join(current))
                current = []
            else:
                current.append(c)
        i += 1
    if current:
        result.append("".join(current))
    return result

def _parse_json_string(s):
    s = s.strip()
    if not s.startswith("\"") or not s.endswith("\""):
        return None
    # Strip quotes and unescape basic sequences
    inner = s[1:-1]
    result = []
    i = 0
    while i < len(inner):
        c = inner[i]
        if c == "\\" and i+1 < len(inner):
            next_c = inner[i+1]
            if next_c == "\"":
                result.append("\"")
            elif next_c == "\\": 
                result.append("\\")
            elif next_c == "n":
                result.append("\n")
            elif next_c == "r":
                result.append("\r")
            elif next_c == "t":
                result.append("\t")
            else:
                result.append(c)
                result.append(next_c)
            i += 2
        else:
            result.append(c)
            i += 1
    return "".join(result)

def _parse_json_value(s):
    s = s.strip()
    if s.startswith("\""):
        return _parse_json_string(s)
    elif s == "true":
        return True
    elif s == "false":
        return False
    elif s == "null":
        return None
    else:
        # Try integer
        if _is_valid_int(s):
            return int(s)
        # Float not strictly needed per spec, but allow it
        if _is_valid_float(s):
            return float(s)
        return None

def _is_valid_int(s):
    if not s:
        return False
    i = 0
    if s[0] == "-" or s[0] == "+":
        i = 1
        if i >= len(s):
            return False
    while i < len(s):
        c = s[i]
        if c < "0" or c > "9":
            return False
        i += 1
    return True

def _is_valid_float(s):
    if not s:
        return False
    i = 0
    if s[0] == "-" or s[0] == "+":
        i = 1
        if i >= len(s):
            return False
    has_dot = False
    has_digit = False
    while i < len(s):
        c = s[i]
        if c == ".":
            if has_dot:
                return False
            has_dot = True
        elif c >= "0" and c <= "9":
            has_digit = True
        else:
            return False
        i += 1
    return has_dot or has_digit
