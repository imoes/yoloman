def main(ctx, params):
    # Required parameters
    namespace_id = params["namespace_id"]
    region = params["region"]
    name = params["name"]
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")

    # Optional parameters with defaults
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)
    query_parameters = params.get("query_parameters", {})

    # Build base URL for region
    base_url = api_url.rstrip("/")
    region_base_url = base_url + "/containers/v1beta1/regions/" + region

    # Helper: build headers
    headers = {
        "Authorization": "Bearer " + api_token,
        "Content-Type": "application/json"
    }

    # Get list of containers
    list_url = region_base_url + "/containers"
    query = dict(query_parameters)
    res = ctx.run(
        ["curl", "-s", "-X", "GET", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", list_url],
        mutates=False
    )
    if res.rc != 0:
        fail("failed to list containers: " + res.stderr)

    # Simple JSON parsing without external module
    def parse_json(s):
        # Strip outer whitespace
        s = s.strip()
        if not s.startswith("{") and not s.startswith("["):
            fail("JSON does not start with '{' or '['")
        # Basic handling for containers list
        if s.startswith("["):
            # Expect [{"containers":[...]}, ...] or just [...]
            # Look for containers array
            containers_key = '"containers"'
            idx = s.find(containers_key)
            if idx != -1:
                start = s.find("[", idx)
                end = s.rfind("]")
                if start != -1 and end != -1 and end > start:
                    s = s[start:end + 1]
            # Parse simple array of objects
            items = []
            level = 0
            start_idx = -1
            for i in range(len(s)):
                c = s[i]
                if c == "[":
                    level += 1
                    if level == 1:
                        start_idx = i + 1
                elif c == "]":
                    level -= 1
                    if level == 0 and start_idx != -1:
                        inner = s[start_idx:i].strip()
                        if inner != "":
                            items.append(inner)
                elif c == "{" and level == 1:
                    start_idx = i
                elif c == "}" and level == 1:
                    # Extract object
                    items.append(s[start_idx:i + 1])
            # Reconstruct as list
            return items
        return None

    # Try to extract containers list manually
    lines = res.stdout.splitlines()
    json_str = "".join(lines).strip()
    containers = []

    # Find the containers array content
    start_idx = json_str.find('"containers"')
    if start_idx != -1:
        start_bracket = json_str.find("[", start_idx)
        if start_bracket != -1:
            depth = 0
            for i in range(start_bracket, len(json_str)):
                c = json_str[i]
                if c == "[":
                    depth += 1
                elif c == "]":
                    depth -= 1
                    if depth == 0:
                        json_str = json_str[start_bracket:i + 1]
                        break

    # Parse JSON array manually
    if json_str.startswith("["):
        # Strip brackets
        inner = json_str[1:-1].strip()
        if inner == "":
            containers = []
        else:
            # Split by top-level objects
            depth = 0
            current = ""
            for i in range(len(inner)):
                c = inner[i]
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        current += c
                        containers.append(current.strip())
                        current = ""
                        continue
                if depth > 0 or (depth == 0 and c != ","):
                    current += c

            # Parse each container dict manually
            parsed_containers = []
            for item in containers:
                obj = {}
                # Simple key-value extraction for needed fields
                # Look for "name": and "id"
                name_start = item.find('"name"')
                if name_start != -1:
                    name_start = item.find('"', name_start + 1) + 1
                    name_end = item.find('"', name_start)
                    if name_end != -1:
                        obj["name"] = item[name_start:name_end]

                id_start = item.find('"id"')
                if id_start != -1:
                    id_start = item.find('"', id_start + 1) + 1
                    id_end = item.find('"', id_start)
                    if id_end != -1:
                        obj["id"] = item[id_start:id_end]

                if len(obj) > 0:
                    parsed_containers.append(obj)

            containers = parsed_containers
    else:
        fail("unexpected response format: containers list not found")

    # Find container by name
    target = None
    for c in containers:
        if type(c) == "dict" and c.get("name") == name:
            target = c
            break

    if target == None:
        fail("container '%s' not found in namespace '%s'" % (name, namespace_id))

    container_id = target.get("id")
    if container_id == None:
        fail("container missing 'id' field")

    # Get detailed container info
    detail_url = region_base_url + "/containers/" + container_id
    res = ctx.run(
        ["curl", "-s", "-X", "GET", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", detail_url],
        mutates=False
    )
    if res.rc != 0:
        fail("failed to get container details: " + res.stderr)

    json_str = res.stdout.strip()

    # Extract container object from response
    start_idx = json_str.find('"container"')
    if start_idx != -1:
        start_bracket = json_str.find("{", start_idx)
        if start_bracket != -1:
            depth = 0
            for i in range(start_bracket, len(json_str)):
                c = json_str[i]
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        json_str = json_str[start_bracket:i + 1]
                        break

    container_info = json_str

    # Parse container info dict manually
    result = {}
    # Extract key fields
    fields = [
        ("name", "string"),
        ("id", "string"),
        ("namespace_id", "string"),
        ("region", "string"),
        ("status", "string"),
        ("privacy", "string"),
        ("protocol", "string"),
        ("domain_name", "string"),
        ("description", "string"),
        ("memory_limit", "int"),
        ("cpu_limit", "int"),
        ("min_scale", "int"),
        ("max_scale", "int"),
        ("max_concurrency", "int"),
        ("timeout", "string"),
        ("http_option", "string"),
        ("port", "int")
    ]

    for field_name, field_type in fields:
        key = '"' + field_name + '"'
        idx = container_info.find(key)
        if idx != -1:
            # Find colon and value
            colon_idx = container_info.find(":", idx)
            if colon_idx != -1:
                start_val = colon_idx + 1
                while start_val < len(container_info) and container_info[start_val] in " \t\n\r":
                    start_val += 1

                if container_info[start_val] == '"':
                    # String value
                    val_start = start_val + 1
                    val_end = val_start
                    while val_end < len(container_info) and container_info[val_end] != '"':
                        if container_info[val_end] == '\\' and val_end + 1 < len(container_info):
                            val_end += 2
                        else:
                            val_end += 1
                    value = container_info[val_start:val_end]
                    result[field_name] = value
                elif field_type == "int":
                    # Integer value
                    end = start_val
                    while end < len(container_info) and container_info[end] in "0123456789-":
                        end += 1
                    value_str = container_info[start_val:end]
                    if value_str != "":
                        result[field_name] = int(value_str)
                else:
                    # Null or boolean
                    if container_info[start_val:].startswith("null"):
                        result[field_name] = None
                    elif container_info[start_val:].startswith("true"):
                        result[field_name] = True
                    elif container_info[start_val:].startswith("false"):
                        result[field_name] = False

    return {"changed": False, "container": result}
