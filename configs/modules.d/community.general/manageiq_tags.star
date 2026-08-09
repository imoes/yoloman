def main(ctx, params):
    # Extract parameters
    state = params.get("state", "present")
    resource_type = params.get("resource_type")
    resource_name = params.get("resource_name")
    resource_id = params.get("resource_id")
    tags = params.get("tags")

    # Validate required parameters
    if resource_type == None:
        fail("resource_type is required")
    if resource_name == None and resource_id == None:
        fail("Either resource_name or resource_id must be specified")
    if resource_name != None and resource_id != None:
        fail("resource_name and resource_id are mutually exclusive")
    if state in ["present", "absent"] and (tags == None or len(tags) == 0):
        fail("tags are required when state is present or absent")

    # Validate resource_type choices
    valid_types = ["provider", "host", "vm", "blueprint", "category", "cluster",
                   "data store", "group", "resource pool", "service",
                   "service template", "template", "tenant", "user"]
    if resource_type not in valid_types:
        fail("resource_type must be one of: " + ", ".join(valid_types))

    # Map state to action
    action = "assign" if state == "present" else "unassign"

    # Extract connection parameters
    conn = params.get("manageiq_connection") or {}
    url = conn.get("url")
    username = conn.get("username")
    password = conn.get("password")
    token = conn.get("token")
    ca_cert = conn.get("ca_cert")
    validate_certs = conn.get("validate_certs", True)

    # Build headers
    headers = {"Content-Type": "application/json"}
    
    # Handle authentication
    auth_header = None
    if token != None:
        auth_header = "Bearer " + token
    elif username != None and password != None:
        auth_header = "Basic " + str(username + ":" + password).encode("utf-8").hex()
    elif "MIQ_TOKEN" in ctx.facts():
        auth_header = "Bearer " + ctx.facts()["MIQ_TOKEN"]
    elif "MIQ_USERNAME" in ctx.facts() and "MIQ_PASSWORD" in ctx.facts():
        auth_header = "Basic " + str(ctx.facts()["MIQ_USERNAME"] + ":" + ctx.facts()["MIQ_PASSWORD"]).encode("utf-8").hex()
    else:
        fail("Authentication credentials required: token or username+password, or environment variables MIQ_TOKEN, MIQ_USERNAME/MIQ_PASSWORD")

    if auth_header != None:
        headers["Authorization"] = auth_header

    # Determine URL
    if url == None:
        url = ctx.facts().get("MIQ_URL")
    if url == None:
        fail("ManageIQ URL is required: passed via manageiq_connection.url or environment variable MIQ_URL")

    # Normalize resource type to ManageIQ API format
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
    resource_type_api = type_map.get(resource_type)
    if resource_type_api == None:
        fail("Unsupported resource_type: " + resource_type)

    # Get resource ID by name if not provided
    if resource_id == None:
        # Query resource by name
        query_url = url + "/api/" + resource_type_api + "?expand=resources&filter[name]=" + resource_name
        res = ctx.run(["curl", "-s", "-X", "GET", "-H", "Authorization: " + auth_header, "-H", "Content-Type: application/json", query_url])
        if res.rc != 0:
            fail("Failed to query resource by name: " + res.stderr)
        
        # Parse JSON response (simple parsing without json module)
        stdout = res.stdout.strip()
        if stdout == "" or not stdout.startswith("{"):
            fail("Invalid response from ManageIQ: no JSON returned")
        
        # Extract resources array
        if '"resources":' not in stdout:
            fail("Resource not found: no matching " + resource_type + " named " + resource_name)
        
        # Find resources array start
        start = stdout.find('"resources":') + len('"resources":')
        end = stdout.find(']', start)
        if end == -1:
            fail("Invalid response format from ManageIQ")
        
        resources_str = stdout[start:end+1]
        # Count objects in array (simple heuristic: count '{')
        count = resources_str.count("{")
        if count == 0:
            fail("Resource not found: no matching " + resource_type + " named " + resource_name)
        if count > 1:
            fail("Multiple resources found with name " + resource_name)
        
        # Extract id from first object
        if '"id":' not in resources_str:
            fail("Resource response missing 'id' field")
        
        id_start = resources_str.find('"id":') + len('"id":')
        # Find end of id (comma, }, or end)
        id_part = resources_str[id_start:]
        id_end = id_part.find(",") if id_part.find(",") != -1 else id_part.find("}")
        if id_end == -1:
            id_end = len(id_part)
        
        resource_id = int(id_part[:id_end].strip())
    
    # Prepare tag data
    tag_list = []
    for t in tags:
        if type(t) == "dict":
            cat = t.get("category")
            name = t.get("name")
            if cat == None or name == None:
                fail("Each tag must include 'category' and 'name' keys")
            tag_list.append({"name": name, "category": cat})
        else:
            fail("Each tag must be a dictionary with 'category' and 'name' keys")
    
    # Build request body
    body = '{"action": "' + action + '", "resources": ['
    for i, tag in enumerate(tag_list):
        if i > 0:
            body += ","
        body += '{"name": "' + tag["name"] + '", "category": {"name": "' + tag["category"] + '"}}'
    body += "]}"

    # Execute request
    api_url = url + "/api/resources/" + str(resource_id) + "/tags"
    curl_args = ["curl", "-s", "-X", "POST", "-H", "Authorization: " + auth_header, "-H", "Content-Type: application/json", "--data", body, api_url]
    if validate_certs == False:
        curl_args.insert(4, "-k")
    if ca_cert != None:
        curl_args.insert(4, "--cacert")
        curl_args.insert(5, ca_cert)
    
    res = ctx.run(curl_args, mutates=True)
    
    # Handle check mode
    if ctx.check_mode:
        return {"changed": True, "msg": "would " + ("assign" if action == "assign" else "remove") + " tags"}
    
    if res.rc != 0:
        fail("Failed to " + action + " tags: " + res.stderr)
    
    # Check response for success
    if '"success"' not in res.stdout:
        fail("Unexpected response from ManageIQ: no success indicator")
    
    return {"changed": True, "msg": "tags " + action + "ed successfully"}
