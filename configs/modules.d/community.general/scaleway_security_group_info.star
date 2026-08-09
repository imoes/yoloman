def main(ctx, params):
    # Required parameters
    region = params["region"]
    api_token = params["api_token"]

    # Optional parameters with defaults
    api_url = params.get("api_url", "https://api.scaleway.com")
    api_timeout = params.get("api_timeout", 30)
    query_parameters = params.get("query_parameters", {})
    validate_certs = params.get("validate_certs", True)

    # Map region to API endpoint (based on SCALEWAY_LOCATION mapping)
    region_endpoints = {
        "ams1": "https://api.scaleway.com/instance/v1/zones/fr-par-1",
        "EMEA-NL-EVS": "https://api.scaleway.com/instance/v1/zones/nl-ams-1",
        "par1": "https://api.scaleway.com/instance/v1/zones/fr-par-1",
        "EMEA-FR-PAR1": "https://api.scaleway.com/instance/v1/zones/fr-par-1",
        "par2": "https://api.scaleway.com/instance/v1/zones/fr-par-2",
        "EMEA-FR-PAR2": "https://api.scaleway.com/instance/v1/zones/fr-par-2",
        "waw1": "https://api.scaleway.com/instance/v1/zones/pl-waw-1",
        "EMEA-PL-WAW1": "https://api.scaleway.com/instance/v1/zones/pl-waw-1"
    }

    if region not in region_endpoints:
        fail("Unsupported region: %s" % region)

    api_endpoint = region_endpoints[region] + "/security_groups"

    # Build query string from query_parameters (simple key=value pairs)
    query_parts = []
    for key in sorted(query_parameters.keys()):
        value = query_parameters[key]
        if type(value) == "list":
            for item in value:
                query_parts.append(str(key) + "=" + str(item))
        else:
            query_parts.append(str(key) + "=" + str(value))
    query_string = "&".join(query_parts)
    full_url = api_endpoint
    if query_string:
        full_url = api_endpoint + "?" + query_string

    # Perform GET request
    res = ctx.run(
        ["curl", "-sSf", "-X", "GET", "-H", "X-Auth-Token: " + api_token, "-H", "Content-Type: application/json", full_url],
        mutates=False
    )

    if res.rc != 0:
        fail("Failed to fetch security groups: " + res.stderr)

    # Parse JSON manually (simple JSON parser for list of objects)
    # Since we cannot import json, we parse basic structure using string operations
    data = res.stdout.strip()
    if not data.startswith("["):
        fail("Unexpected API response format")
    # Extract list content between first [ and last ]
    start = data.find("[")
    end = data.rfind("]")
    if start == -1 or end == -1 or end <= start:
        fail("Malformed JSON response")
    list_content = data[start+1:end]

    groups = []
    # Split by },{ pattern to get individual group objects
    # This is a simplified parser that handles well-formed JSON
    depth = 0
    current = ""
    for char in list_content:
        if char == '{':
            depth += 1
        if char == '}':
            depth -= 1
        current += char
        if depth == 0 and current.strip():
            obj = _parse_simple_json_object(current.strip())
            if obj != None:
                groups.append(obj)
            current = ""
    if depth != 0:
        fail("Malformed JSON object nesting")

    return {"changed": False, "msg": "Security groups retrieved", "data": {"scaleway_security_group_info": groups}}


def _parse_simple_json_object(s):
    # Very basic JSON object parser for known structure
    s = s.strip()
    if not s.startswith("{") or not s.endswith("}"):
        return None

    content = s[1:-1].strip()
    if not content:
        return {}

    result = {}
    # Split key-value pairs by comma (simple case)
    pairs = []
    depth = 0
    current = ""
    in_string = False
    escape = False
    for char in content:
        if escape:
            current += char
            escape = False
            continue
        if char == '\\':
            if in_string:
                escape = True
                current += char
                continue
        if char == '"':
            in_string = not in_string
        if not in_string:
            if char == '[' or char == '{':
                depth += 1
            elif char == ']' or char == '}':
                depth -= 1
            elif char == ',' and depth == 0:
                pairs.append(current.strip())
                current = ""
                continue
        current += char
    if current.strip():
        pairs.append(current.strip())

    for pair in pairs:
        if ":" not in pair:
            continue
        idx = pair.find(":")
        key = pair[:idx].strip().strip('"')
        value = pair[idx+1:].strip()

        # Parse value type
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        elif value == "true":
            value = True
        elif value == "false":
            value = False
        elif value == "null":
            value = None
        elif _is_integer(value):
            value = int(value)
        elif _is_float(value):
            value = float(value)
        elif value.startswith("["):
            value = _parse_simple_json_array(value)
        elif value.startswith("{"):
            # Nested object — simplified: get content inside braces
            inner = _extract_braces(value)
            obj = _parse_simple_json_object(inner)
            if obj != None:
                value = obj
            else:
                value = None
        else:
            value = value

        if key != "":
            result[key] = value

    return result


def _parse_simple_json_array(s):
    s = s.strip()
    if not s.startswith("[") or not s.endswith("]"):
        return []

    content = s[1:-1].strip()
    if not content:
        return []

    result = []
    depth = 0
    current = ""
    in_string = False
    escape = False
    for char in content:
        if escape:
            current += char
            escape = False
            continue
        if char == '\\':
            if in_string:
                escape = True
                current += char
                continue
        if char == '"':
            in_string = not in_string
        if not in_string:
            if char == '[' or char == '{':
                depth += 1
            elif char == ']' or char == '}':
                depth -= 1
            elif char == ',' and depth == 0:
                item = current.strip()
                if item:
                    # Try to parse item
                    if item.startswith('"') and item.endswith('"'):
                        item = item[1:-1]
                    elif item == "true":
                        item = True
                    elif item == "false":
                        item = False
                    elif item == "null":
                        item = None
                    elif _is_integer(item):
                        item = int(item)
                    elif _is_float(item):
                        item = float(item)
                    elif item.startswith("{"):
                        inner = _extract_braces(item)
                        obj = _parse_simple_json_object(inner)
                        item = obj if obj != None else None
                    result.append(item)
                current = ""
                continue
        current += char
    if current.strip():
        item = current.strip()
        if item.startswith('"') and item.endswith('"'):
            item = item[1:-1]
        elif item == "true":
            item = True
        elif item == "false":
            item = False
        elif item == "null":
            item = None
        elif _is_integer(item):
            item = int(item)
        elif _is_float(item):
            item = float(item)
        elif item.startswith("{"):
            inner = _extract_braces(item)
            obj = _parse_simple_json_object(inner)
            item = obj if obj != None else None
        result.append(item)

    return result


def _extract_braces(s):
    # Extract content between outer braces (first { and matching })
    if not s.startswith("{"):
        return s
    depth = 0
    start = -1
    for i, char in enumerate(s):
        if char == '{':
            if depth == 0:
                start = i
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return s[start+1:i]
    return s[1:-1]


def _is_integer(s):
    s = s.strip()
    if not s:
        return False
    if s.startswith("-"):
        s = s[1:]
    return s.isdigit()


def _is_float(s):
    s = s.strip()
    if not s:
        return False
    # Handle optional sign
    if s.startswith("+") or s.startswith("-"):
        s = s[1:]
    # Must contain exactly one dot and digits around it
    if s.count(".") != 1:
        return False
    parts = s.split(".")
    if len(parts) != 2:
        return False
    left = parts[0]
    right = parts[1]
    # Either part can be empty only if the other is non-empty and digit-only
    if not left and not right:
        return False
    if left and not left.isdigit():
        return False
    if right and not right.isdigit():
        return False
    return True
