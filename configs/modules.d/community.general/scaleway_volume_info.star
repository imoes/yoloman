def main(ctx, params):
    api_token = params.get("api_token")
    if api_token == None:
        fail("api_token is required")
    api_url = params.get("api_url", "https://api.scaleway.com").rstrip("/")
    region = params.get("region")
    if region == None:
        fail("region is required")

    query_parameters = params.get("query_parameters", {})
    api_timeout = int(params.get("api_timeout", 30))
    validate_certs = params.get("validate_certs", True)

    region_map = {
        "ams1": {"api_endpoint": "https://api.scaleway.com/instance/v1/zones/fr-par-1"},
        "EMEA-NL-EVS": {"api_endpoint": "https://api.scaleway.com/instance/v1/zones/nl-ams-1"},
        "par1": {"api_endpoint": "https://api.scaleway.com/instance/v1/zones/fr-par-1"},
        "EMEA-FR-PAR1": {"api_endpoint": "https://api.scaleway.com/instance/v1/zones/fr-par-1"},
        "par2": {"api_endpoint": "https://api.scaleway.com/instance/v1/zones/fr-par-2"},
        "EMEA-FR-PAR2": {"api_endpoint": "https://api.scaleway.com/instance/v1/zones/fr-par-2"},
        "waw1": {"api_endpoint": "https://api.scaleway.com/instance/v1/zones/pl-waw-1"},
        "EMEA-PL-WAW1": {"api_endpoint": "https://api.scaleway.com/instance/v1/zones/pl-waw-1"},
    }

    if region not in region_map:
        fail("unsupported region: %s" % region)
    api_url = region_map[region]["api_endpoint"]

    # Build query string
    query_parts = []
    for k in sorted(query_parameters.keys()):
        v = query_parameters[k]
        if type(v) == "list":
            for item in v:
                query_parts.append("%s=%s" % (k, str(item)))
        else:
            query_parts.append("%s=%s" % (k, str(v)))
    query_str = "&".join(query_parts)
    url = api_url + "/volumes" + ("?" + query_str if query_str else "")

    headers = {
        "Authorization": "Bearer " + api_token,
        "Content-Type": "application/json",
    }

    res = ctx.run(
        ["curl", "-sS", "-X", "GET", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", url],
        mutates=False
    )

    if res.rc != 0:
        fail("failed to fetch volumes: " + res.stderr)

    data = res.stdout.strip()
    # Expecting: {"volumes": [...], ...} or just [...]
    # Simple heuristic: find 'volumes' key
    if '"volumes":' in data:
        start = data.find('"volumes":') + len('"volumes":')
        while start < len(data) and data[start] in ' \t\n\r':
            start += 1
        if start >= len(data) or data[start] != '[':
            fail("malformed API response: missing list")
        brace_count = 0
        end = start
        for i in range(start, len(data)):
            if data[i] == '[' or data[i] == '{':
                brace_count += 1
            elif data[i] == ']' or data[i] == '}':
                brace_count -= 1
                if brace_count == 0 and data[i] == ']':
                    end = i + 1
                    break
        data = data[start:end]
    # Strip outer brackets
    data = data.strip()
    if not (data.startswith('[') and data.endswith(']')):
        fail("malformed API response: not a list")
    data = data[1:-1].strip()
    volumes = []
    if data:
        # Split top-level objects by '},{' but avoid nested ones
        items = []
        depth = 0
        item_start = 0
        for i, c in enumerate(data):
            if c == '{':
                if depth == 0:
                    item_start = i
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    items.append(data[item_start:i+1])
        for item in items:
            vol = {}
            # Extract key-value pairs: "key": value
            pos = 0
            item = item.strip()
            while pos < len(item):
                # Skip leading whitespace
                while pos < len(item) and item[pos] in ' \t\n\r':
                    pos += 1
                if pos >= len(item) or item[pos] != '"':
                    break
                # Find key
                pos += 1
                key_end = item.find('"', pos)
                if key_end == -1:
                    break
                key = item[pos:key_end]
                pos = key_end + 1
                # Skip whitespace and colon
                while pos < len(item) and item[pos] in ' \t\n\r':
                    pos += 1
                if pos >= len(item) or item[pos] != ':':
                    break
                pos += 1
                # Skip whitespace
                while pos < len(item) and item[pos] in ' \t\n\r':
                    pos += 1
                # Parse value
                if pos >= len(item):
                    break
                if item[pos] == '"':
                    pos += 1
                    val_end = pos
                    while val_end < len(item) and item[val_end] != '"':
                        if item[val_end] == '\\' and val_end + 1 < len(item):
                            val_end += 2
                        else:
                            val_end += 1
                    val = item[pos:val_end]
                    pos = val_end + 1
                elif item[pos:pos+4] == 'None':
                    vol[key] = None
                    pos += 4
                    continue
                elif item[pos] == '-' or item[pos].isdigit():
                    val_str = ""
                    if item[pos] == '-':
                        val_str += item[pos]
                        pos += 1
                    while pos < len(item) and (item[pos].isdigit() or item[pos] == '.'):
                        val_str += item[pos]
                        pos += 1
                    if '.' in val_str:
                        val = float(val_str)
                    else:
                        val = int(val_str)
                    vol[key] = val
                else:
                    # Skip unknown
                    break
            volumes.append(vol)

    return {
        "changed": False,
        "msg": "fetched volumes",
        "data": {"scaleway_volume_info": volumes}
    }
