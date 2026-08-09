def main(ctx, params):
    project_id = params["project_id"]
    name = params["name"]
    region = params["region"]
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)
    query_parameters = params.get("query_parameters", {})

    # Validate region
    valid_regions = ["fr-par", "nl-ams", "pl-waw"]
    if region not in valid_regions:
        fail("invalid region '%s'; must be one of: %s" % (region, ", ".join(valid_regions)))

    # Build request URL
    api_path = "containers/v1beta1/regions/%s/namespaces" % region
    list_url = "%s/%s" % (api_url.rstrip("/"), api_path)

    # Prepare query string
    query_parts = []
    if project_id:
        query_parts.append("project_id=" + project_id)
    query_parts.append("name=" + name)
    for k, v in query_parameters.items():
        if k not in ["name", "project_id"]:
            query_parts.append(str(k) + "=" + str(v))

    if query_parts:
        list_url = list_url + "?" + "&".join(query_parts)

    # Fetch namespaces list
    res = ctx.run(
        ["curl", "-sS", "-f", "-X", "GET", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", list_url],
        mutates=False
    )
    if res.rc != 0:
        fail("failed to list namespaces: %s" % res.stderr)

    # Parse JSON array manually (simple parser for known format)
    data = res.stdout.strip()
    if not data.startswith("[") or not data.endswith("]"):
        fail("invalid namespaces list response: expected JSON array")

    # Extract content between [ and ]
    items_str = data[1:len(data)-1].strip()

    namespaces = []
    if items_str == "":
        namespaces = []
    else:
        # Naive parsing: split on },{ and reconstruct objects
        # Ensure we handle nested braces properly (simplified for known structure)
        depth = 0
        current = ""
        for i in range(len(items_str)):
            c = items_str[i]
            if c == "{":
                depth += 1
                current += c
            elif c == "}":
                depth -= 1
                current += c
                if depth == 0:
                    namespaces.append(current)
                    current = ""
            elif c == "," and depth == 0:
                continue  # Skip top-level commas
            else:
                current += c

    # Lookup by name
    found = None
    for ns in namespaces:
        name_key = '"name":'
        idx = ns.find(name_key)
        if idx == -1:
            continue
        start = ns.find('"', idx + len(name_key))
        if start == -1:
            continue
        end = ns.find('"', start + 1)
        if end == -1:
            continue
        ns_name = ns[start+1:end]
        if ns_name == name:
            found = ns
            break

    if found == None:
        fail("no container namespace named '%s' found in project '%s', region '%s'" % (name, project_id, region))

    # Extract ID from found namespace
    id_key = '"id":'
    idx = found.find(id_key)
    if idx == -1:
        fail("malformed namespace response: missing 'id'")
    start = found.find('"', idx + len(id_key))
    if start == -1:
        fail("malformed namespace response: missing 'id' value")
    end = found.find('"', start + 1)
    if end == -1:
        fail("malformed namespace response: missing 'id' value")
    ns_id = found[start+1:end]

    # Get full namespace details
    detail_url = "%s/%s" % (api_url.rstrip("/"), api_path + "/" + ns_id)

    res = ctx.run(
        ["curl", "-sS", "-f", "-X", "GET", "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", detail_url],
        mutates=False
    )
    if res.rc != 0:
        fail("failed to get namespace details: %s" % res.stderr)

    # Return result
    return {
        "changed": False,
        "msg": "namespace %s retrieved" % name,
        "container_namespace": res.stdout.strip()  # raw JSON string
    }
