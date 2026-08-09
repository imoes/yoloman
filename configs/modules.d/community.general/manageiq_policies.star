def main(ctx, params):
    # Required params
    resource_type = params["resource_type"]
    state = params.get("state", "present")
    
    # Mutually exclusive: resource_id vs resource_name
    resource_id = params.get("resource_id")
    resource_name = params.get("resource_name")
    if (resource_id == None) == (resource_name == None):
        fail("Exactly one of resource_id or resource_name must be specified")
    
    # policy_profiles required for both present/absent states
    policy_profiles = params.get("policy_profiles", [])
    if len(policy_profiles) == 0:
        fail("policy_profiles is required when state is present or absent")

    # Validate resource_type
    valid_types = ["provider", "host", "vm", "blueprint", "category", "cluster",
                   "data store", "group", "resource pool", "service", "service template",
                   "template", "tenant", "user"]
    if resource_type not in valid_types:
        fail("Invalid resource_type '%s'. Must be one of: %s" % (resource_type, ", ".join(valid_types)))
    
    # Map resource_type to ManageIQ internal type
    type_map = {
        "provider": "Provider",
        "host": "Host",
        "vm": "VmOrTemplate",
        "blueprint": "Blueprint",
        "category": "Category",
        "cluster": "ManageIQ::Providers::InfraManager::Cluster",
        "data store": "Storage",
        "group": "UserGroup",
        "resource pool": "ManageIQ::Providers::InfraManager::ResourcePool",
        "service": "Service",
        "service template": "ServiceTemplate",
        "template": "VmOrTemplate",
        "tenant": "Tenant",
        "user": "User"
    }
    manageiq_type = type_map.get(resource_type)
    
    # Get connection parameters
    conn = params.get("manageiq_connection", {})
    url = conn.get("url") or ctx.facts().get("miq_url", "")
    username = conn.get("username")
    password = conn.get("password")
    token = conn.get("token")
    
    # Auth: prefer token, then username+password
    if token == None:
        if username == None or password == None:
            fail("Authentication credentials required (token or username+password)")
        # Note: Basic auth not supported in this implementation
        fail("Username/password authentication is not supported. Please use token authentication.")
    
    # Get resource ID if only resource_name provided
    if resource_id == None:
        # Query by name
        res = ctx.run([
            "curl", "-s", "-k",
            "-H", "X-Auth-Token: " + token,
            "-H", "Content-Type: application/json",
            url + "/api/" + manageiq_type + "?expand=resources&filter[name]=" + resource_name
        ], mutates=False)
        if res.rc != 0:
            fail("Failed to query resource by name: " + res.stderr)
        
        # Extract ID from response
        response = res.stdout
        if '"resources":' not in response:
            fail("Unexpected API response format")
        
        # Find resource with matching name
        found_name = False
        lines = response.splitlines()
        for line in lines:
            if '"name":' in line and resource_name in line:
                found_name = True
                break
        if not found_name:
            fail("Resource not found by name: " + resource_name)
        
        # Extract ID
        id_pos = response.find('"id":')
        if id_pos == -1:
            fail("Could not extract resource ID from response")
        
        id_str = response[id_pos+5:].split(",")[0].strip()
        resource_id = int(id_str)
    
    # Get current profiles
    res = ctx.run([
        "curl", "-s", "-k",
        "-H", "X-Auth-Token: " + token,
        "-H", "Content-Type: application/json",
        url + "/api/resources/" + str(resource_id) + "?expand=policies,policy_profiles"
    ], mutates=False)
    if res.rc != 0:
        fail("Failed to query current policy profiles: " + res.stderr)

    current_profiles = []
    response = res.stdout
    if '"policy_profiles":' in response:
        start_idx = response.find('"policy_profiles":') + len('"policy_profiles":')
        end_idx = response.find('"policies":', start_idx)
        if end_idx == -1:
            end_idx = len(response)
        profiles_json = response[start_idx:end_idx].strip()
        
        # Extract profile names
        start_profile = 0
        while True:
            name_pos = profiles_json.find('"name":', start_profile)
            if name_pos == -1:
                break
            name_start = profiles_json.find('"', name_pos + 6) + 1
            name_end = profiles_json.find('"', name_start)
            profile_name = profiles_json[name_start:name_end]
            current_profiles.append(profile_name)
            start_profile = name_end + 1
    
    # Prepare profiles to modify
    desired_profiles = []
    for p in policy_profiles:
        name = p.get("name")
        if name != None:
            desired_profiles.append(name)
    
    # Calculate changes
    if state == "present":
        to_add = []
        for p in desired_profiles:
            found = False
            for c in current_profiles:
                if p == c:
                    found = True
                    break
            if not found:
                to_add.append(p)
        to_remove = []
    else:  # absent
        to_add = []
        to_remove = []
        for p in desired_profiles:
            for c in current_profiles:
                if p == c:
                    to_remove.append(p)
                    break
    
    if len(to_add) == 0 and len(to_remove) == 0:
        return {
            "changed": False,
            "msg": "Policy profiles already in desired state",
            "profiles": current_profiles
        }

    # Apply changes
    if ctx.check_mode:
        if len(to_add) > 0:
            msg = "Would assign policy profiles: " + ", ".join(to_add)
        else:
            msg = "Would unassign policy profiles: " + ", ".join(to_remove)
        return {"changed": True, "msg": msg}

    # Perform the action
    if len(to_add) > 0:
        action_url = "/api/resources/" + str(resource_id) + "/policy_profiles"
        # Build JSON manually
        profiles_array = "["
        for i in range(len(to_add)):
            if i > 0:
                profiles_array += ","
            profiles_array += '{"name": "' + to_add[i] + '"}'
        profiles_array += "]"
        body = '{"action": "assign", "resources": ' + profiles_array + '}'
    else:
        action_url = "/api/resources/" + str(resource_id) + "/policy_profiles"
        profiles_array = "["
        for i in range(len(to_remove)):
            if i > 0:
                profiles_array += ","
            profiles_array += '{"name": "' + to_remove[i] + '"}'
        profiles_array += "]"
        body = '{"action": "unassign", "resources": ' + profiles_array + '}'

    res = ctx.run([
        "curl", "-s", "-k",
        "-X", "POST",
        "-H", "X-Auth-Token: " + token,
        "-H", "Content-Type: application/json",
        "-d", body,
        url + action_url
    ], mutates=True)
    if res.rc != 0:
        fail("Failed to modify policy profiles: " + res.stderr)

    # Verify changes
    res = ctx.run([
        "curl", "-s", "-k",
        "-H", "X-Auth-Token: " + token,
        "-H", "Content-Type: application/json",
        url + "/api/resources/" + str(resource_id) + "?expand=policies,policy_profiles"
    ], mutates=False)
    if res.rc != 0:
        fail("Failed to verify policy profiles: " + res.stderr)

    new_profiles = []
    response = res.stdout
    if '"policy_profiles":' in response:
        start_idx = response.find('"policy_profiles":') + len('"policy_profiles":')
        end_idx = response.find('"policies":', start_idx)
        if end_idx == -1:
            end_idx = len(response)
        profiles_json = response[start_idx:end_idx].strip()
        
        start_profile = 0
        while True:
            name_pos = profiles_json.find('"name":', start_profile)
            if name_pos == -1:
                break
            name_start = profiles_json.find('"', name_pos + 6) + 1
            name_end = profiles_json.find('"', name_start)
            profile_name = profiles_json[name_start:name_end]
            new_profiles.append(profile_name)
            start_profile = name_end + 1

    msg = ""
    if len(to_add) > 0:
        msg = "Assigned policy profiles: " + ", ".join(to_add)
    if len(to_remove) > 0:
        if msg != "":
            msg += "; "
        msg += "Unassigned policy profiles: " + ", ".join(to_remove)

    return {
        "changed": True,
        "msg": msg,
        "profiles": new_profiles
    }
