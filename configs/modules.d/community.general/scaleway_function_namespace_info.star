def main(ctx, params):
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    project_id = params["project_id"]
    region = params["region"]
    name = params["name"]
    query_parameters = params.get("query_parameters", {})
    validate_certs = params.get("validate_certs", True)
    api_timeout = params.get("api_timeout", 30)

    # Validate region
    valid_regions = ["fr-par", "nl-ams", "pl-waw"]
    if region not in valid_regions:
        fail("Invalid region '%s'. Must be one of: %s" % (region, ", ".join(valid_regions)))

    # Construct API endpoint
    api_path = "/functions/v1beta1/regions/%s/namespaces" % region

    # Build request URL for listing namespaces
    list_url = api_url.rstrip("/") + api_path

    # Build query parameters
    query = {}
    query["project_id"] = project_id
    # Merge user-provided query parameters
    if query_parameters != None:
        for k in query_parameters.keys():
            query[k] = query_parameters.get(k)

    # Build query string manually
    query_parts = []
    for k in sorted(query.keys()):
        query_parts.append(str(k) + "=" + str(query.get(k)))
    full_url = list_url
    if len(query_parts) > 0:
        full_url = full_url + "?" + "&".join(query_parts)

    # Perform GET request to list namespaces
    headers = [
        "Authorization: Bearer " + api_token,
        "Content-Type: application/json"
    ]
    curl_args = ["curl", "-sS", "-X", "GET", full_url]
    for h in headers:
        curl_args.extend(["-H", h])

    res = ctx.run(curl_args, mutates=False)
    if res.rc != 0:
        fail("Failed to list namespaces: " + res.stderr)

    # Parse JSON manually: locate namespaces array
    data = res.stdout
    ns_start = data.find('"namespaces"')
    if ns_start == -1:
        fail("Could not find 'namespaces' in API response")

    arr_start = data.find("[", ns_start)
    if arr_start == -1:
        fail("Could not find '[' after 'namespaces'")

    # Find matching ']' (simple counting)
    arr_end = arr_start + 1
    depth = 1
    while arr_end < len(data) and depth > 0:
        c = data[arr_end]
        if c == '[':
            depth += 1
        elif c == ']':
            depth -= 1
        arr_end += 1
    if depth != 0:
        fail("Could not find end of 'namespaces' array")

    namespaces_json = data[arr_start:arr_end]

    # Parse array elements (naive parser)
    namespaces_list = []
    items_str = namespaces_json.strip()[1:-1]  # remove outer []
    if items_str != "":
        current = ""
        depth = 0
        in_string = False
        escape = False
        for i in range(len(items_str)):
            c = items_str[i]
            if escape:
                current += c
                escape = False
                continue
            if c == '\\':
                escape = True
                current += c
                continue
            if c == '"':
                in_string = not in_string
                current += c
                continue
            if not in_string:
                if c == '{':
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth == 0:
                        item = current.strip()
                        if item != "":
                            namespaces_list.append(item)
                        current = ""
                        continue
            current += c

    # Search for target namespace by name
    target_ns = None
    for ns_str in namespaces_list:
        name_start = ns_str.find('"name":')
        if name_start == -1:
            continue
        name_start += len('"name":')
        while name_start < len(ns_str) and (ns_str[name_start] == ' ' or ns_str[name_start] == '"'):
            name_start += 1
        if name_start >= len(ns_str) or ns_str[name_start] != '"':
            continue
        name_start += 1
        name_end = ns_str.find('"', name_start)
        if name_end == -1:
            continue
        ns_name = ns_str[name_start:name_end]
        if ns_name == name:
            target_ns = ns_str
            break

    if target_ns == None:
        fail("Error: Unable to find function namespace named '%s' in project '%s'" % (name, project_id))

    # Extract id from target namespace
    id_start = target_ns.find('"id":')
    if id_start == -1:
        fail("Error: Could not find 'id' in namespace object")
    id_start += len('"id":')
    while id_start < len(target_ns) and target_ns[id_start] == ' ':
        id_start += 1
    if id_start >= len(target_ns) or target_ns[id_start] != '"':
        fail("Error: 'id' value not quoted")
    id_start += 1
    id_end = target_ns.find('"', id_start)
    if id_end == -1:
        fail("Error: Could not find end of 'id' value")
    namespace_id = target_ns[id_start:id_end]

    # Fetch individual namespace details by ID
    detail_url = api_url.rstrip("/") + api_path + "/" + namespace_id

    curl_args = ["curl", "-sS", "-X", "GET", detail_url]
    for h in headers:
        curl_args.extend(["-H", h])

    res = ctx.run(curl_args, mutates=False)
    if res.rc != 0:
        fail("Failed to get namespace details: " + res.stderr)

    res_json = res.stdout

    # Extract key fields manually
    # Extract status
    status_start = res_json.find('"status":')
    status = "unknown"
    if status_start != -1:
        status_start += len('"status":')
        while status_start < len(res_json) and res_json[status_start] == ' ':
            status_start += 1
        if status_start < len(res_json) and res_json[status_start] == '"':
            status_start += 1
            status_end = res_json.find('"', status_start)
            if status_end != -1:
                status = res_json[status_start:status_end]

    # Prepare simplified namespace info dict
    ns_info = {
        "id": namespace_id,
        "name": name,
        "status": status,
        "project_id": project_id,
        "region": region,
        "raw": res_json
    }

    return {"changed": False, "function_namespace": ns_info, "msg": "Successfully retrieved function namespace information"}
