def main(ctx, params):
    # Extract required parameters
    resource_type = params["resource_type"]
    resource_id = params.get("resource_id")
    resource_name = params.get("resource_name")

    # Validate mutual exclusivity and required_one_of (simulated)
    if resource_id != None and resource_name != None:
        fail("resource_id and resource_name are mutually exclusive")
    if resource_id == None and resource_name == None:
        fail("one of resource_id or resource_name is required")

    # Map resource_type to ManageIQ internal type (simplified)
    type_map = {
        "provider": "providers",
        "host": "hosts",
        "vm": "vms",
        "blueprint": "blueprints",
        "category": "categories",
        "cluster": "clusters",
        "data store": "data_stores",
        "group": "groups",
        "resource pool": "resource_pools",
        "service": "services",
        "service template": "service_templates",
        "template": "templates",
        "tenant": "tenants",
        "user": "users"
    }
    if resource_type not in type_map:
        fail("unsupported resource_type: " + resource_type)
    miq_resource_type = type_map[resource_type]

    # Build ManageIQ connection headers
    manageiq_url = params.get("manageiq_connection", {}).get("url")
    if manageiq_url == None:
        manageiq_url = ctx.run(["env", "MIQ_URL"], stdout=True, stderr=True, mutates=False).stdout.strip()
    manageiq_url = manageiq_url.strip()
    if manageiq_url == "":
        fail("ManageIQ URL is required (use manageiq_connection.url or MIQ_URL env)")

    manageiq_user = params.get("manageiq_connection", {}).get("username")
    manageiq_pass = params.get("manageiq_connection", {}).get("password")
    manageiq_token = params.get("manageiq_connection", {}).get("token")
    
    # Priority: token > username+password > MIQ_TOKEN > MIQ_USERNAME+MIQ_PASSWORD
    if manageiq_token == None:
        manageiq_token = ctx.run(["env", "MIQ_TOKEN"], stdout=True, stderr=True, mutates=False).stdout.strip()
    if manageiq_token != None and manageiq_token != "":
        auth_header = "Bearer " + manageiq_token
    else:
        if manageiq_user == None:
            manageiq_user = ctx.run(["env", "MIQ_USERNAME"], stdout=True, stderr=True, mutates=False).stdout.strip()
        if manageiq_pass == None:
            manageiq_pass = ctx.run(["env", "MIQ_PASSWORD"], stdout=True, stderr=True, mutates=False).stdout.strip()
        if manageiq_user == "" or manageiq_user == None:
            fail("ManageIQ username is required (use manageiq_connection.username or MIQ_USERNAME env)")
        if manageiq_pass == "" or manageiq_pass == None:
            fail("ManageIQ password is required (use manageiq_connection.password or MIQ_PASSWORD env)")
        # Basic auth: encode "user:pass" in base64 (no external deps; use simple approach)
        auth_str = manageiq_user + ":" + manageiq_pass
        # Simulate base64 by using echo + base64 command (standard POSIX tool)
        b64_res = ctx.run(["sh", "-c", "echo -n '%s' | base64" % auth_str], stdout=True, stderr=True, mutates=False)
        auth_header = "Basic " + b64_res.stdout.strip()

    verify_certs = params.get("manageiq_connection", {}).get("validate_certs", True)
    ca_cert = params.get("manageiq_connection", {}).get("ca_cert", "")

    # If resource_id not provided, query by name
    if resource_id == None:
        # Use ManageIQ API to find resource by name
        query_url = manageiq_url + "/api/" + miq_resource_type + "?filter[]=" + resource_name
        headers = ["-H", "Authorization: " + auth_header]
        if not verify_certs:
            headers.extend(["-k"])
        if ca_cert != "":
            headers.extend(["--cacert", ca_cert])
        
        # Run curl to query resource by name
        res = ctx.run(
            ["curl", "-s", "-S"] + headers + ["-X", "GET", query_url],
            stdout=True, stderr=True, mutates=False
        )
        if res.rc != 0:
            fail("failed to query resource by name: " + res.stderr)
        # Parse JSON manually: expect list with one element
        # Use simple string parsing (no json module)
        output = res.stdout.strip()
        if not output.startswith("[") or not output.endswith("]"):
            fail("unexpected API response format")
        # Extract first object ID
        # Simple heuristic: find "id" : <number> pattern
        id_pos = output.find('"id"')
        if id_pos == -1:
            id_pos = output.find("'id'")
        if id_pos == -1:
            fail("could not parse resource ID from API response")
        colon_pos = output.find(":", id_pos)
        if colon_pos == -1:
            fail("could not parse resource ID from API response")
        # Find end of number (digits)
        start = colon_pos + 1
        while start < len(output) and (output[start] == " " or output[start] == "\t"):
            start += 1
        end = start
        while end < len(output) and output[end].isdigit():
            end += 1
        if start == end:
            fail("could not parse resource ID from API response")
        resource_id = int(output[start:end])

    # Now query tags for the resource
    tags_url = manageiq_url + "/api/" + miq_resource_type + "/" + str(resource_id) + "/tags"
    headers = ["-H", "Authorization: " + auth_header]
    if not verify_certs:
        headers.extend(["-k"])
    if ca_cert != "":
        headers.extend(["--cacert", ca_cert])

    tags_res = ctx.run(
        ["curl", "-s", "-S"] + headers + ["-X", "GET", tags_url],
        stdout=True, stderr=True, mutates=False
    )
    if tags_res.rc != 0:
        fail("failed to query tags: " + tags_res.stderr)

    # Parse tags JSON: expect {"resources": [...]} or similar structure
    # Simplified parsing for expected format: list of tag dicts with "name", "category", etc.
    output = tags_res.stdout.strip()
    if not output.startswith("["):
        # Try to find the array inside the response (e.g., {"resources": [...]})
        start_idx = output.find('"resources"')
        if start_idx != -1:
            start_bracket = output.find("[", start_idx)
            end_bracket = output.rfind("]")
            if start_bracket != -1 and end_bracket != -1:
                output = output[start_bracket:end_bracket+1]
        if not output.startswith("["):
            fail("unexpected tags API response format")

    # Parse list of tags: each tag is an object like {"name": "...", "category": {"name": "..."}}
    tags = []
    # Very simple parser for flat array of objects
    # Split by "},{" to separate objects (assumes no nested braces in values)
    if output == "[]":
        return {"changed": False, "tags": []}
    
    # Remove outer brackets
    content = output[1:-1].strip()
    if content == "":
        return {"changed": False, "tags": []}

    # Split on },{ — approximate for simple cases
    # For more robustness, split only when outside quotes and braces
    # But given constraints, use a safe split strategy:
    obj_strs = []
    depth = 0
    current = ""
    in_str = False
    i = 0
    while i < len(content):
        c = content[i]
        if c == '"' and (i == 0 or content[i-1] != '\\'):
            in_str = not in_str
            current += c
        elif not in_str:
            if c == '{':
                depth += 1
                current += c
            elif c == '}':
                depth -= 1
                current += c
                if depth == 0:
                    obj_strs.append(current.strip())
                    current = ""
            elif c == ',' and depth == 0:
                current = ""
            else:
                current += c
        else:
            current += c
        i += 1
    if current.strip() != "":
        obj_strs.append(current.strip())

    for obj_str in obj_strs:
        if not obj_str.startswith("{") or not obj_str.endswith("}"):
            continue
        # Extract key-value pairs
        tag = {}
        # Extract name
        name_start = obj_str.find('"name"')
        if name_start != -1:
            name_colon = obj_str.find(":", name_start)
            if name_colon != -1:
                quote1 = obj_str.find('"', name_colon+1)
                if quote1 != -1:
                    quote2 = obj_str.find('"', quote1+1)
                    if quote2 != -1:
                        tag["name"] = obj_str[quote1+1:quote2]
        # Extract category name
        cat_start = obj_str.find('"category"')
        if cat_start != -1:
            # Find nested object
            cat_brace = obj_str.find("{", cat_start)
            if cat_brace != -1:
                cat_end = obj_str.find("}", cat_brace)
                if cat_end != -1:
                    cat_obj = obj_str[cat_brace:cat_end+1]
                    cat_name_start = cat_obj.find('"name"')
                    if cat_name_start != -1:
                        cat_name_colon = cat_obj.find(":", cat_name_start)
                        if cat_name_colon != -1:
                            cat_quote1 = cat_obj.find('"', cat_name_colon+1)
                            if cat_quote1 != -1:
                                cat_quote2 = cat_obj.find('"', cat_quote1+1)
                                if cat_quote2 != -1:
                                    tag["category"] = {"name": cat_obj[cat_quote1+1:cat_quote2]}
        if "name" in tag:
            tags.append(tag)

    return {"changed": False, "tags": tags}
