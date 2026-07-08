def main(ctx, params):
    # Required parameters
    project_id = params["project_id"]
    region = params["region"]
    name = params["name"]
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)
    query_parameters = params.get("query_parameters", {})

    # Validate region
    valid_regions = ["fr-par", "nl-ams", "pl-waw"]
    if region not in valid_regions:
        fail("invalid region '%s'. Must be one of: %s" % (region, ", ".join(valid_regions)))

    # Build API path for listing namespaces
    api_path = "/registry/v1/regions/%s/namespaces" % region
    full_url = api_url.rstrip("/") + api_path

    # Build query string manually
    params_list = {}
    if query_parameters:
        params_list.update(query_parameters)
    # Add project_id filter if not already present
    if "project_id" not in params_list:
        params_list["project_id"] = project_id

    query_parts = []
    for k, v in sorted(params_list.items()):
        query_parts.append(str(k) + "=" + str(v))
    query_string = "&".join(query_parts)
    full_url_query = full_url + ("?" + query_string if query_string else "")

    # GET /registry/v1/regions/{region}/namespaces
    res = ctx.run(
        ["curl", "-sSL", "-X", "GET", "-H", "X-Auth-Token: " + api_token, "-H", "Content-Type: application/json", full_url_query],
        mutates=False
    )
    if res.rc != 0:
        fail("failed to list container namespaces: " + res.stderr)

    # Parse JSON manually — assume well-formed JSON with simple structure
    data = res.stdout
    start_idx = data.find("[")
    end_idx = data.rfind("]")
    if start_idx == -1 or end_idx == -1:
        fail("invalid JSON response from Scaleway API")
    json_str = data[start_idx:end_idx + 1]

    # Extract list of namespaces
    namespaces = []
    inner = json_str[1:-1].strip()
    if inner:
        # Split by },{ while respecting brace depth
        objects = []
        brace_depth = 0
        current = ""
        for c in inner:
            if c == '{':
                brace_depth += 1
            elif c == '}':
                brace_depth -= 1
                if brace_depth == 0:
                    current += c
                    objects.append(current.strip())
                    current = ""
                    continue
            elif c == ',' and brace_depth == 0:
                continue
            current += c

        # Parse each object string into dict
        for obj_str in objects:
            obj = {}
            obj_inner = obj_str[1:-1].strip()
            pairs = obj_inner.split(",")
            for pair in pairs:
                if ":" not in pair:
                    continue
                key_str, val_str = pair.split(":", 1)
                key = key_str.strip().strip('"').strip()
                val_raw = val_str.strip()
                if val_raw.startswith('"') and val_raw.endswith('"'):
                    val = val_raw[1:-1]
                elif val_raw == "true":
                    val = True
                elif val_raw == "false":
                    val = False
                elif val_raw == "null":
                    val = None
                else:
                    # Try integer conversion first, fallback to float, else keep string
                    if val_raw.isdigit() or (val_raw.startswith("-") and val_raw[1:].isdigit()):
                        val = int(val_raw)
                    elif val_raw.replace(".", "").replace("-", "").isdigit() and val_raw.count(".") == 1:
                        val = float(val_raw)
                    else:
                        val = val_raw
                obj[key] = val
            namespaces.append(obj)

    # Lookup by name
    target = None
    for ns in namespaces:
        if ns.get("name") == name and ns.get("project_id") == project_id:
            target = ns
            break

    if target == None:
        fail("container registry '%s' not found in project '%s' (region %s)" % (name, project_id, region))

    # Now GET /registry/v1/regions/{region}/namespaces/{id}
    ns_id = target.get("id")
    if ns_id == None:
        fail("namespace missing 'id' field")

    full_url_get = api_url.rstrip("/") + "/registry/v1/regions/%s/namespaces/%s" % (region, ns_id)
    res_get = ctx.run(
        ["curl", "-sSL", "-X", "GET", "-H", "X-Auth-Token: " + api_token, "-H", "Content-Type: application/json", full_url_get],
        mutates=False
    )
    if res_get.rc != 0:
        fail("failed to get container registry details: " + res_get.stderr)

    # Parse JSON response for the single registry object
    data_get = res_get.stdout
    start_idx = data_get.find("{")
    end_idx = data_get.rfind("}")
    if start_idx == -1 or end_idx == -1:
        fail("invalid JSON response from Scaleway API (get details)")
    json_str_get = data_get[start_idx:end_idx + 1]

    registry = {}
    obj_inner = json_str_get[1:-1].strip()
    if obj_inner:
        pairs = obj_inner.split(",")
        for pair in pairs:
            if ":" not in pair:
                continue
            key_str, val_str = pair.split(":", 1)
            key = key_str.strip().strip('"').strip()
            val_raw = val_str.strip()
            if val_raw.startswith('"') and val_raw.endswith('"'):
                val = val_raw[1:-1]
            elif val_raw == "true":
                val = True
            elif val_raw == "false":
                val = False
            elif val_raw == "null":
                val = None
            else:
                # Try integer conversion first, fallback to float, else keep string
                if val_raw.isdigit() or (val_raw.startswith("-") and val_raw[1:].isdigit()):
                    val = int(val_raw)
                elif val_raw.replace(".", "").replace("-", "").isdigit() and val_raw.count(".") == 1:
                    val = float(val_raw)
                else:
                    val = val_raw
            registry[key] = val

    return {"changed": False, "container_registry": registry}
