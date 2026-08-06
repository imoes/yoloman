def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)
    headers = params.get("headers", {})

    if state != "present":
        fail("state other than 'present' is not supported by this info module")

    url = "%s://%s:%s/api/objects/network/interface_address?search=%s" % (
        utm_protocol,
        utm_host,
        str(utm_port),
        name,
    )

    # Build headers
    request_headers = {"X-Token": utm_token}
    for key in headers:
        request_headers[key] = headers[key]

    res = ctx.run(
        [
            "curl",
            "-s",
            "-k" if not validate_certs else "",
            "-X",
            "GET",
            "-H",
            "Content-Type: application/json",
            "-H",
            "X-Token: " + utm_token,
            url,
        ],
        mutates=False,
    )
    if res.skipped:
        # In check_mode, simulate successful fetch
        return {
            "changed": False,
            "msg": "would fetch info for " + name,
            "result": {
                "name": name,
                "found": False,
            },
        }
    if res.rc != 0:
        fail("failed to retrieve interface address info: " + res.stderr)

    # Parse JSON manually (no json module)
    stdout = res.stdout.strip()
    if not stdout:
        return {
            "changed": False,
            "msg": "no data returned for " + name,
            "result": {
                "name": name,
                "found": False,
            },
        }

    # Simple JSON parser for expected list format: [{"key": "value", ...}]
    # Look for entries with matching 'name' field
    entries = []
    current = None
    key = ""
    value = ""
    i = 0
    n = len(stdout)
    inside_string = False
    escape = False
    brace_depth = 0
    bracket_depth = 0

    while i < n:
        c = stdout[i]

        if inside_string:
            if escape:
                value += c
                escape = False
            elif c == "\\":
                escape = True
            elif c == '"':
                inside_string = False
                if key:
                    entries.append((key, value))
                    key = ""
                    value = ""
            else:
                value += c
        else:
            if c == '"':
                inside_string = True
                key = ""
            elif c == ":":
                key = key.strip()
                value = ""
            elif c == "{" and not key:
                brace_depth += 1
                current = {}
            elif c == "{" and key:
                # Nested object - skip for now
                pass
            elif c == "}" and brace_depth > 0:
                brace_depth -= 1
                if brace_depth == 0:
                    if current:
                        entries.append(current)
                        current = None
                key = ""
            elif c == "[":
                bracket_depth += 1
            elif c == "]":
                bracket_depth -= 1
        i += 1

    # Alternative: find the JSON array and parse manually more robustly
    # Since this is Starlark, do minimal parsing of JSON-like structure
    # Instead, rely on the fact that the output should be a JSON array
    # and use find() and split() to extract entries

    # Fallback: try basic regex-free extraction
    # Look for the pattern '"name": "some_name"' in the string
    found_entry = None
    lines = stdout.splitlines()
    current_obj = {}
    for line in lines:
        line = line.strip()
        if line == "{":
            current_obj = {}
        elif line == "}" and current_obj:
            # Check if this entry matches name
            if current_obj.get("name") == name:
                found_entry = current_obj
                break
        else:
            # Try to parse key-value pairs like '"key": "value"' or '"key": value'
            if ":" in line:
                # Simple split on first colon
                sep_pos = line.find(":")
                k = line[:sep_pos].strip().strip('"')
                rest = line[sep_pos + 1 :].strip()
                # Strip quotes if present
                if rest.startswith('"'):
                    # Find closing quote, allowing escapes
                    end = -1
                    j = 1
                    while j < len(rest):
                        if rest[j] == '"' and rest[j - 1] != '\\':
                            end = j
                            break
                        j += 1
                    if end > 0:
                        v = rest[1:end].replace('\\"', '"')
                    else:
                        v = rest[1:].strip()
                else:
                    # Numeric or bool
                    v = rest.strip()
                    if v == "true":
                        v = True
                    elif v == "false":
                        v = False
                    elif v.isdigit():
                        v = int(v)
                    elif v.replace(".", "").isdigit():
                        v = float(v)
                    elif v == "null":
                        v = None
                current_obj[k] = v

    # Return result
    if found_entry == None:
        return {
            "changed": False,
            "msg": "no interface address named '" + name + "' found",
            "result": {
                "name": name,
                "found": False,
            },
        }

    return {
        "changed": False,
        "msg": "found interface address " + name,
        "result": {
            "name": found_entry.get("name"),
            "_ref": found_entry.get("_ref"),
            "_locked": found_entry.get("_locked"),
            "_type": found_entry.get("_type"),
            "address": found_entry.get("address"),
            "address6": found_entry.get("address6"),
            "comment": found_entry.get("comment"),
            "resolved": found_entry.get("resolved"),
            "resolved6": found_entry.get("resolved6"),
            "found": True,
        },
    }
