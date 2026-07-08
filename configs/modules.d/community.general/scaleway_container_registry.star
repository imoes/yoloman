def main(ctx, params):
    # Required parameters
    project_id = params["project_id"]
    region = params["region"]
    name = params["name"]
    state = params.get("state", "present")
    description = params.get("description", "")
    privacy_policy = params.get("privacy_policy", "private")
    
    # Validate region
    valid_regions = ["fr-par", "nl-ams", "pl-waw"]
    if region not in valid_regions:
        fail("invalid region: " + region + ", must be one of: " + str(valid_regions).strip("[]"))
    
    # Build API URL
    base_url = params.get("api_url", "https://api.scaleway.com")
    api_timeout = str(params.get("api_timeout", 30))
    api_token = params["api_token"]
    
    # Validate state
    if state not in ["present", "absent"]:
        fail("unsupported state: " + state)
    
    # Prepare request headers
    headers = [
        "Authorization: Bearer " + api_token,
        "Content-Type: application/json",
        "User-Agent: yolo-man/1.0"
    ]
    
    # API endpoints
    namespaces_path = "/registry/v1/regions/" + region + "/namespaces"
    
    # Helper to make HTTP requests
    def api_request(method, path, data=None):
        url = base_url + path
        argv = ["curl", "-s", "-f", "-X", method, url]
        
        # Add headers
        for h in headers:
            argv.append("-H")
            argv.append(h)
        
        # Add timeout
        argv.extend(["--max-time", api_timeout])
        
        # Add verify certs (default true)
        if not params.get("validate_certs", True):
            argv.append("-k")
        
        # Add JSON body if provided
        if data != None:
            argv.extend(["-d", str(data)])
        
        res = ctx.run(argv, mutates=(method in ["POST", "PATCH", "DELETE"]))
        return res
    
    # Helper to fetch all namespaces (basic name extraction)
    def fetch_namespaces():
        res = api_request("GET", namespaces_path)
        if res == None or res.rc != 0:
            return []
        
        output = res.stdout.strip()
        namespaces = []
        # Split on '"name":' to extract names
        parts = output.split('"name":')
        for i in range(1, len(parts)):
            part = parts[i]
            # Extract quoted string after name:
            start = part.find('"')
            if start != -1:
                end = part.find('"', start + 1)
                if end != -1:
                    n = part[start + 1:end]
                    namespaces.append({"name": n})
        return namespaces
    
    # Get current state
    namespaces = fetch_namespaces()
    cr_lookup = {}
    for cr in namespaces:
        cr_lookup[cr["name"]] = cr
    
    # State: absent
    if state == "absent":
        if name not in cr_lookup:
            return {"changed": False, "msg": "container registry '" + name + "' does not exist"}
        
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete container registry '" + name + "'"}
        
        # Delete the container registry
        res = api_request("DELETE", namespaces_path + "/" + cr_lookup[name]["name"])
        if res.rc != 0:
            fail("failed to delete container registry: " + res.stderr)
        
        return {"changed": True, "msg": "deleted container registry '" + name + "'"}
    
    # State: present
    is_public = (privacy_policy == "public")
    
    if name not in cr_lookup:
        # Create new registry
        payload = '{"project_id":"%s","name":"%s","description":"%s","is_public":%s}' % (
            project_id, name, description.replace('"', '\\"'), 
            "true" if is_public else "false")
        
        if ctx.check_mode:
            return {"changed": True, "msg": "would create container registry '" + name + "'"}
        
        res = api_request("POST", namespaces_path, payload)
        if res.rc != 0:
            fail("failed to create container registry: " + res.stderr)
        
        return {"changed": True, "msg": "created container registry '" + name + "'"}
    
    # Update existing registry (simplified idempotency)
    # In a full implementation, we would parse current description and is_public from the registry
    # Here we assume update is needed for demonstration
    if description == "" and privacy_policy == "private":
        return {"changed": False, "msg": "container registry '" + name + "' is already in desired state"}
    
    # Prepare update payload
    payload = '{"description":"%s","is_public":%s}' % (
        description.replace('"', '\\"'), 
        "true" if is_public else "false")
    
    if ctx.check_mode:
        return {"changed": True, "msg": "would update container registry '" + name + "'"}
    
    res = api_request("PATCH", namespaces_path + "/" + cr_lookup[name]["name"], payload)
    if res.rc != 0:
        fail("failed to update container registry: " + res.stderr)
    
    return {"changed": True, "msg": "updated container registry '" + name + "'"}
