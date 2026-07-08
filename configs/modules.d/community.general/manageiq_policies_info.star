def main(ctx, params):
    resource_type = params["resource_type"]
    resource_name = params.get("resource_name")
    resource_id = params.get("resource_id")
    
    # Validate required parameters
    if resource_id == None and resource_name == None:
        fail("One of resource_id or resource_name is required")
    if resource_id != None and resource_name != None:
        fail("resource_id and resource_name are mutually exclusive")
    
    # Map resource_type to ManageIQ internal type
    type_map = {
        "provider": "Provider",
        "host": "Host",
        "vm": "VmOrTemplate",
        "blueprint": "Blueprint",
        "category": "Category",
        "cluster": "Cluster",
        "data store": "Datastore",
        "group": "Group",
        "resource pool": "ResourcePool",
        "service": "Service",
        "service template": "ServiceTemplate",
        "template": "VmOrTemplate",
        "tenant": "Tenant",
        "user": "User"
    }
    
    if resource_type not in type_map:
        fail("Unsupported resource_type: " + resource_type)
    manageiq_type = type_map[resource_type]
    
    # Build query URL path
    if resource_name != None:
        path = "/api/" + manageiq_type.lower() + "s?name=" + resource_name
    else:
        path = "/api/" + manageiq_type.lower() + "s/" + str(resource_id)
    
    # Get connection parameters
    conn = params.get("manageiq_connection", {})
    url = conn.get("url") or ctx.facts().get("MIQ_URL", "")
    username = conn.get("username") or ctx.facts().get("MIQ_USERNAME", "")
    password = conn.get("password") or ctx.facts().get("MIQ_PASSWORD", "")
    token = conn.get("token") or ctx.facts().get("MIQ_TOKEN", "")
    ca_cert = conn.get("ca_cert")
    verify = not (conn.get("validate_certs") == False)
    
    if url == "":
        fail("URL is required (provide manageiq_connection.url or set MIQ_URL environment variable)")
    
    # Build authentication
    auth_header = ""
    if token != None:
        auth_header = "X-Auth-Token: " + token
    elif username != None and password != None:
        # Build basic auth header: base64(username:password)
        # Starlark doesn't have base64, so we use curl with -u option
        pass
    else:
        fail("Authentication required (username/password or token)")
    
    # Query resource details using curl with -u option for auth
    curl_args = ["curl", "-s", "-S", "-X", "GET", "-H", "Content-Type: application/json", "-H", "Accept: application/json"]
    
    # Handle auth via curl options
    if username != None and password != None:
        curl_args = curl_args + ["-u", username + ":" + password]
    elif token != None:
        curl_args = curl_args + ["-H", "X-Auth-Token: " + token]
    
    if ca_cert != None:
        curl_args = curl_args + ["--cacert", ca_cert]
    if not verify:
        curl_args = curl_args + ["--insecure"]
    
    curl_args = curl_args + [url + path]
    
    res = ctx.run(curl_args, mutates=False)
    if res.rc != 0:
        fail("Failed to query ManageIQ: " + res.stderr)
    
    # Parse JSON response manually using string operations
    data = _parse_json_response(res.stdout)
    if data == None:
        fail("Invalid response from ManageIQ: no valid data found")
    
    # Extract resource info
    resources = data.get("resources", [])
    if len(resources) == 0:
        fail("No resource found matching criteria")
    
    # For name-based lookup, filter by exact name match
    if resource_name != None:
        matched = []
        for r in resources:
            if r.get("name") == resource_name:
                matched.append(r)
        if len(matched) == 0:
            fail("No resource found with name " + resource_name)
        resource = matched[0]
    else:
        resource = resources[0]
    
    # Query policy profiles
    profiles_url = url + "/api/resources/" + str(resource["id"]) + "/policy_profiles"
    curl_args2 = ["curl", "-s", "-S", "-X", "GET", "-H", "Content-Type: application/json", "-H", "Accept: application/json"]
    
    if username != None and password != None:
        curl_args2 = curl_args2 + ["-u", username + ":" + password]
    elif token != None:
        curl_args2 = curl_args2 + ["-H", "X-Auth-Token: " + token]
    
    if ca_cert != None:
        curl_args2 = curl_args2 + ["--cacert", ca_cert]
    if not verify:
        curl_args2 = curl_args2 + ["--insecure"]
    
    curl_args2 = curl_args2 + [profiles_url]
    
    res2 = ctx.run(curl_args2, mutates=False)
    if res2.rc != 0:
        fail("Failed to query policy profiles: " + res2.stderr)
    
    profiles_data = _parse_json_response(res2.stdout)
    profiles = profiles_data.get("resources", [])
    
    # Format the result
    formatted_profiles = []
    for profile in profiles:
        formatted_profile = {
            "profile_name": profile.get("name", ""),
            "profile_description": profile.get("description", ""),
            "policies": []
        }
        
        # Get policies for this profile
        policies_url = url + "/api/policy_profiles/" + str(profile["id"]) + "/policies"
        curl_args3 = ["curl", "-s", "-S", "-X", "GET", "-H", "Content-Type: application/json", "-H", "Accept: application/json"]
        
        if username != None and password != None:
            curl_args3 = curl_args3 + ["-u", username + ":" + password]
        elif token != None:
            curl_args3 = curl_args3 + ["-H", "X-Auth-Token: " + token]
        
        if ca_cert != None:
            curl_args3 = curl_args3 + ["--cacert", ca_cert]
        if not verify:
            curl_args3 = curl_args3 + ["--insecure"]
        
        curl_args3 = curl_args3 + [policies_url]
        
        res3 = ctx.run(curl_args3, mutates=False)
        if res3.rc == 0:
            policies_data = _parse_json_response(res3.stdout)
            for policy in policies_data.get("resources", []):
                formatted_policy = {
                    "name": policy.get("name", ""),
                    "description": policy.get("description", ""),
                    "active": bool(policy.get("active", False))
                }
                formatted_profile["policies"].append(formatted_policy)
    
        formatted_profiles.append(formatted_profile)
    
    return {"changed": False, "profiles": formatted_profiles}


def _parse_json_response(s):
    """Parse minimal JSON response for ManageIQ API structure."""
    s = s.strip()
    if s == "" or s == "null":
        return None
    
    # Handle empty arrays
    if s == "[]":
        return {"resources": []}
    
    # Handle basic object structure - extract resources array
    if s.startswith("{") and s.endswith("}"):
        # Simple extraction for {"resources": [...]} pattern
        resources_start = s.find('"resources"')
        if resources_start >= 0:
            # Find the array after "resources"
            colon_pos = s.find(":", resources_start)
            if colon_pos >= 0:
                bracket_start = s.find("[", colon_pos)
                bracket_end = s.rfind("]")
                if bracket_start >= 0 and bracket_end > bracket_start:
                    arr_str = s[bracket_start:bracket_end+1]
                    return {"resources": _parse_resource_array(arr_str)}
        return None
    
    # Handle array directly
    if s.startswith("[") and s.endswith("]"):
        return {"resources": _parse_resource_array(s)}
    
    return None


def _parse_resource_array(arr_str):
    """Parse a simple resource array string into list of dicts."""
    arr_str = arr_str.strip()
    if arr_str == "[]":
        return []
    
    # Remove brackets
    arr_str = arr_str[1:-1].strip()
    if arr_str == "":
        return []
    
    # Split by },{ pattern
    items = []
    depth = 0
    current = ""
    for c in arr_str:
        if c == '{':
            depth += 1
            if depth == 1:
                current = ""
            else:
                current += c
        elif c == '}':
            depth -= 1
            if depth == 0:
                items.append(current.strip())
            else:
                current += c
        elif depth > 0:
            current += c
    
    result = []
    for item in items:
        item_dict = _parse_object(item)
        if item_dict != None:
            result.append(item_dict)
    return result


def _parse_object(obj_str):
    """Parse a simple object string into dict."""
    obj_str = obj_str.strip()
    if obj_str == "" or obj_str == "{}":
        return {}
    
    result = {}
    # Split by commas at depth 0
    parts = _split_object_parts(obj_str)
    for part in parts:
        part = part.strip()
        if part == "":
            continue
        
        colon_pos = part.find(":")
        if colon_pos > 0:
            key = part[:colon_pos].strip().strip('"')
            value = part[colon_pos+1:].strip()
            
            # Parse value
            value = value.strip('"')
            if value == "true":
                value = True
            elif value == "false":
                value = False
            elif value == "null" or value == "":
                value = None
            elif value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                value = int(value)
            
            result[key] = value
    
    return result


def _split_object_parts(obj_str):
    """Split object string by commas at depth 0."""
    parts = []
    depth = 0
    current = ""
    i = 0
    while i < len(obj_str):
        c = obj_str[i]
        if c == '{':
            depth += 1
            current += c
        elif c == '}':
            depth -= 1
            current += c
        elif c == '[':
            depth += 1
            current += c
        elif c == ']':
            depth -= 1
            current += c
        elif c == ',' and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += c
        i += 1
    
    if current.strip() != "":
        parts.append(current.strip())
    
    return parts
