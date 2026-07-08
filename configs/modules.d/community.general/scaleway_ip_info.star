def main(ctx, params):
    api_token = params.get("api_token")
    if api_token == None:
        fail("api_token is required")
    region = params.get("region")
    if region == None:
        fail("region is required")
    api_timeout = params.get("api_timeout", 30)
    api_url = params.get("api_url", "https://api.scaleway.com")
    validate_certs = params.get("validate_certs", True)
    query_parameters = params.get("query_parameters", {})

    # Map region to api_endpoint (matching SCALEWAY_LOCATION)
    region_map = {
        "ams1": "https://api.scaleway.com/instance/v1/zones/fr-par-1",
        "EMEA-NL-EVS": "https://api.scaleway.com/instance/v1/zones/nl-ams-1",
        "par1": "https://api.scaleway.com/instance/v1/zones/fr-par-1",
        "EMEA-FR-PAR1": "https://api.scaleway.com/instance/v1/zones/fr-par-1",
        "par2": "https://api.scaleway.com/instance/v1/zones/fr-par-2",
        "EMEA-FR-PAR2": "https://api.scaleway.com/instance/v1/zones/fr-par-2",
        "waw1": "https://api.scaleway.com/instance/v1/zones/pl-waw-1",
        "EMEA-PL-WAW1": "https://api.scaleway.com/instance/v1/zones/pl-waw-1"
    }
    endpoint = region_map.get(region)
    if endpoint == None:
        fail("unsupported region: " + region)

    # Build query string from query_parameters
    query_parts = []
    for key in sorted(query_parameters.keys()):
        value = query_parameters[key]
        if type(value) == "list":
            for v in value:
                query_parts.append(key + "=" + str(v))
        else:
            query_parts.append(key + "=" + str(value))
    query_str = ""
    if len(query_parts) > 0:
        query_str = "?" + "&".join(query_parts)

    # Get IPs endpoint
    url = endpoint + "/ips" + query_str

    res = ctx.run(
        ["curl", "-sSf", "-X", "GET", "-H", "X-Auth-Token: " + api_token, url],
        mutates=False
    )
    if res.rc != 0:
        fail("failed to fetch IPs: " + res.stderr)

    # Parse JSON manually (simple list parsing)
    stdout = res.stdout.strip()
    if len(stdout) == 0:
        fail("empty response from Scaleway API")
    if not (stdout.startswith("[") and stdout.endswith("]")):
        fail("unexpected response format")

    # Extract list entries manually
    ips = []
    depth = 0
    current = ""
    in_string = False
    escape = False
    for ch in stdout:
        if escape:
            current += ch
            escape = False
            continue
        if ch == "\\" and in_string:
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            current += ch
            continue
        if not in_string:
            if ch == '{':
                if depth == 1:
                    current = ch
                else:
                    current += ch
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 1:
                    current += ch
                    # End of one IP object
                    entry = parse_ip_entry(current)
                    ips.append(entry)
                    current = ""
                else:
                    current += ch
            elif depth > 0:
                current += ch
            elif ch == ',':
                current = ""
        else:
            current += ch

    return {"changed": False, "msg": "fetched IPs", "data": {"scaleway_ip_info": ips}}


def parse_ip_entry(entry_str):
    result = {}
    # Extract "key": value or "key": null or "key": {...}
    parts = split_json_object(entry_str)
    for part in parts:
        part = part.strip()
        if part == "":
            continue
        colon = part.find(":")
        if colon <= 0:
            continue
        key = part[1:colon-1].strip()  # remove quotes
        value_part = part[colon+1:].strip()
        if value_part.startswith("{"):
            # Nested object
            nested = extract_nested(value_part)
            result[key] = parse_ip_entry(nested)
        elif value_part == "null":
            result[key] = None
        elif value_part.startswith('"'):
            result[key] = value_part[1:-1]
        else:
            # Try to parse as integer without try/except
            if value_part.isdigit() or (value_part.startswith("-") and value_part[1:].isdigit()):
                result[key] = int(value_part)
            else:
                result[key] = value_part
    return result


def split_json_object(obj_str):
    # Strip outer braces
    if not (obj_str.startswith("{") and obj_str.endswith("}")):
        return []
    obj_str = obj_str[1:-1].strip()
    if obj_str == "":
        return []

    parts = []
    depth = 0
    current = ""
    in_string = False
    escape = False
    for ch in obj_str:
        if escape:
            current += ch
            escape = False
            continue
        if ch == "\\" and in_string:
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            current += ch
            continue
        if not in_string:
            if ch == '{' or ch == '[':
                depth += 1
                current += ch
            elif ch == '}' or ch == ']':
                depth -= 1
                current += ch
            elif ch == ',' and depth == 0:
                parts.append(current)
                current = ""
            else:
                current += ch
        else:
            current += ch
    if current.strip() != "":
        parts.append(current)
    return parts


def extract_nested(str_val):
    if not str_val.startswith("{"):
        return str_val
    depth = 0
    end = -1
    for i, ch in enumerate(str_val):
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                end = i
                break
    if end >= 0:
        return str_val[:end+1]
    return str_val
