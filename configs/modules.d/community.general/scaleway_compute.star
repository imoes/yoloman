def main(ctx, params):
    # Required parameters
    region = params["region"]
    commercial_type = params["commercial_type"]
    image = params["image"]
    api_token = params["api_token"]
    
    # Optional parameters with defaults
    api_url = params.get("api_url", "https://api.scaleway.com")
    api_timeout = params.get("api_timeout", 30)
    name = params.get("name")
    organization = params.get("organization")
    project = params.get("project")
    public_ip = params.get("public_ip", "absent")
    enable_ipv6 = params.get("enable_ipv6", False)
    state = params.get("state", "present")
    tags = params.get("tags", [])
    security_group = params.get("security_group")
    wait = params.get("wait", False)
    wait_timeout = params.get("wait_timeout", 300)
    wait_sleep_time = params.get("wait_sleep_time", 3)
    validate_certs = params.get("validate_certs", True)
    
    # Validate region
    valid_regions = ["ams1", "EMEA-NL-EVS", "par1", "EMEA-FR-PAR1", "par2", "EMEA-FR-PAR2", "waw1", "EMEA-PL-WAW1"]
    if region not in valid_regions:
        fail("Invalid region %s. Must be one of: %s" % (region, ", ".join(valid_regions)))
    
    # Validate state
    valid_states = ["present", "absent", "running", "restarted", "stopped"]
    if state not in valid_states:
        fail("Invalid state %s. Must be one of: %s" % (state, ", ".join(valid_states)))
    
    # Exactly one of organization or project must be specified
    if organization == None and project == None:
        fail("One of 'organization' or 'project' must be specified")
    if organization != None and project != None:
        fail("Only one of 'organization' or 'project' can be specified")
    
    # Determine the API endpoint for the region
    region_endpoints = {
        "ams1": "https://api.scaleway.com/compute/v1/zones/ams1",
        "EMEA-NL-EVS": "https://api.scaleway.com/compute/v1/zones/ams1",
        "par1": "https://api.scaleway.com/compute/v1/zones/par1",
        "EMEA-FR-PAR1": "https://api.scaleway.com/compute/v1/zones/par1",
        "par2": "https://api.scaleway.com/compute/v1/zones/par2",
        "EMEA-FR-PAR2": "https://api.scaleway.com/compute/v1/zones/par2",
        "waw1": "https://api.scaleway.com/compute/v1/zones/waw1",
        "EMEA-PL-WAW1": "https://api.scaleway.com/compute/v1/zones/waw1"
    }
    api_base_url = region_endpoints.get(region, api_url)
    
    # Validate image exists
    res = ctx.run(
        ["curl", "-s", "-f", "-X", "GET", api_base_url + "/images/" + image],
        mutates=False
    )
    if res.rc != 0:
        fail("Image %s not found" % image)
    
    # Determine instance identifier (by name if provided, otherwise search by name)
    instance_id = None
    instances = []
    
    # Fetch existing instances with the given name
    if name != None:
        query_url = api_base_url + "/servers?name=" + name + "&per_page=100"
        res = ctx.run(["curl", "-s", "-f", "-X", "GET", query_url], mutates=False)
        if res.rc == 0:
            # Parse JSON manually using string operations
            stdout = res.stdout.strip()
            # Find servers array
            start_idx = stdout.find("\"servers\"")
            if start_idx != -1:
                start_brace = stdout.find("[", start_idx)
                end_brace = stdout.find("]", start_brace)
                if start_brace != -1 and end_brace != -1:
                    servers_json = stdout[start_brace:end_brace+1]
                    # Simple parsing - extract id/name/state for each server
                    # Look for "id": "...", "name": "...", "state": "..."
                    current = 0
                    while True:
                        id_idx = servers_json.find("\"id\"", current)
                        if id_idx == -1:
                            break
                        # Find start of ID value
                        colon_idx = servers_json.find(":", id_idx)
                        quote_start = servers_json.find("\"", colon_idx)
                        quote_end = servers_json.find("\"", quote_start+1)
                        if quote_start != -1 and quote_end != -1:
                            srv_id = servers_json[quote_start+1:quote_end]
                            
                            # Find name
                            name_idx = servers_json.find("\"name\"", quote_end)
                            if name_idx != -1:
                                colon_idx2 = servers_json.find(":", name_idx)
                                quote_start2 = servers_json.find("\"", colon_idx2)
                                quote_end2 = servers_json.find("\"", quote_start2+1)
                                if quote_start2 != -1 and quote_end2 != -1:
                                    srv_name = servers_json[quote_start2+1:quote_end2]
                                else:
                                    srv_name = ""
                            else:
                                srv_name = ""
                            
                            # Find state
                            state_idx = servers_json.find("\"state\"", quote_end2)
                            if state_idx != -1:
                                colon_idx3 = servers_json.find(":", state_idx)
                                quote_start3 = servers_json.find("\"", colon_idx3)
                                quote_end3 = servers_json.find("\"", quote_start3+1)
                                if quote_start3 != -1 and quote_end3 != -1:
                                    srv_state = servers_json[quote_start3+1:quote_end3]
                                else:
                                    srv_state = ""
                            else:
                                srv_state = ""
                            
                            instances.append({
                                "id": srv_id,
                                "name": srv_name,
                                "state": srv_state
                            })
                        current = end_brace
    
    # Find instance by name if not found by ID
    if name != None:
        for inst in instances:
            if inst.get("name") == name:
                instance_id = inst.get("id")
                break
    
    # Define state transitions
    def fetch_state(instance_id):
        res = ctx.run(
            ["curl", "-s", "-f", "-X", "GET", api_base_url + "/servers/" + instance_id],
            mutates=False
        )
        if res.rc != 0:
            return "absent"
        stdout = res.stdout.strip()
        # Extract state from JSON response
        state_idx = stdout.find("\"state\"")
        if state_idx != -1:
            colon_idx = stdout.find(":", state_idx)
            quote_start = stdout.find("\"", colon_idx)
            quote_end = stdout.find("\"", quote_start+1)
            if quote_start != -1 and quote_end != -1:
                return stdout[quote_start+1:quote_end]
        return "unknown"
    
    def wait_for_state(instance_id, target_state, timeout, sleep_time):
        elapsed = 0
        while elapsed < timeout:
            current_state = fetch_state(instance_id)
            if current_state == target_state:
                return True
            if current_state not in ["stopping", "starting", "pending"]:
                return False
            ctx.run(["sleep", str(sleep_time)])
            elapsed += sleep_time
        fail("Timeout waiting for state %s (current: %s)" % (target_state, fetch_state(instance_id)))
    
    def create_server():
        # Build JSON payload manually
        payload_lines = []
        payload_lines.append("{\"commercial_type\":\"" + commercial_type + "\"")
        payload_lines.append(",\"image\":\"" + image + "\"")
        payload_lines.append(",\"enable_ipv6\":" + str(enable_ipv6).lower())
        if tags != None and len(tags) > 0:
            tag_list = []
            for t in tags:
                tag_list.append("\"" + t + "\"")
            payload_lines.append(",\"tags\":[" + ",".join(tag_list) + "]")
        if name != None:
            payload_lines.append(",\"name\":\"" + name + "\"")
        if project != None:
            payload_lines.append(",\"project\":\"" + project + "\"")
        if organization != None:
            payload_lines.append(",\"organization\":\"" + organization + "\"")
        if security_group != None:
            payload_lines.append(",\"security_group\":{\"id\":\"" + security_group + "\"}")
        if public_ip in ["dynamic", "allocated"]:
            payload_lines.append(",\"dynamic_ip_required\":true")
        elif public_ip != "absent":
            payload_lines.append(",\"public_ip\":\"" + public_ip + "\"")
        payload_lines.append("}")
        payload = "".join(payload_lines)
        
        res = ctx.run(
            ["curl", "-s", "-f", "-X", "POST", api_base_url + "/servers",
             "-H", "Authorization: Bearer " + api_token,
             "-H", "Content-Type: application/json",
             "-d", payload],
            mutates=False
        )
        if res.rc != 0:
            fail("Failed to create server: " + res.stderr)
        
        # Parse response to get server ID
        stdout = res.stdout.strip()
        id_idx = stdout.find("\"id\"")
        if id_idx != -1:
            colon_idx = stdout.find(":", id_idx)
            quote_start = stdout.find("\"", colon_idx)
            quote_end = stdout.find("\"", quote_start+1)
            if quote_start != -1 and quote_end != -1:
                return stdout[quote_start+1:quote_end]
        return None
    
    def stop_server(instance_id):
        res = ctx.run(
            ["curl", "-s", "-f", "-X", "POST", api_base_url + "/servers/" + instance_id + "/action",
             "-H", "Authorization: Bearer " + api_token,
             "-H", "Content-Type: application/json",
             "-d", "{\"action\":\"poweroff\"}"],
            mutates=True
        )
        if res.rc != 0:
            fail("Failed to stop server: " + res.stderr)
    
    def start_server(instance_id):
        res = ctx.run(
            ["curl", "-s", "-f", "-X", "POST", api_base_url + "/servers/" + instance_id + "/action",
             "-H", "Authorization: Bearer " + api_token,
             "-H", "Content-Type: application/json",
             "-d", "{\"action\":\"poweron\"}"],
            mutates=True
        )
        if res.rc != 0:
            fail("Failed to start server: " + res.stderr)
    
    def restart_server(instance_id):
        res = ctx.run(
            ["curl", "-s", "-f", "-X", "POST", api_base_url + "/servers/" + instance_id + "/action",
             "-H", "Authorization: Bearer " + api_token,
             "-H", "Content-Type: application/json",
             "-d", "{\"action\":\"reboot\"}"],
            mutates=True
        )
        if res.rc != 0:
            fail("Failed to restart server: " + res.stderr)
    
    def delete_server(instance_id):
        # Server must be stopped before deletion
        current_state = fetch_state(instance_id)
        if current_state != "stopped":
            stop_server(instance_id)
            wait_for_state(instance_id, "stopped", wait_timeout, wait_sleep_time)
        
        res = ctx.run(
            ["curl", "-s", "-f", "-X", "DELETE", api_base_url + "/servers/" + instance_id,
             "-H", "Authorization: Bearer " + api_token],
            mutates=True
        )
        if res.rc != 0:
            fail("Failed to delete server: " + res.stderr)
    
    def update_server(instance_id, payload):
        res = ctx.run(
            ["curl", "-s", "-f", "-X", "PATCH", api_base_url + "/servers/" + instance_id,
             "-H", "Authorization: Bearer " + api_token,
             "-H", "Content-Type: application/json",
             "-d", payload],
            mutates=True
        )
        if res.rc != 0:
            fail("Failed to update server: " + res.stderr)
    
    # Main state logic
    if state == "absent":
        if instance_id == None:
            return {"changed": False, "msg": "Server already absent"}
        if ctx.check_mode:
            return {"changed": True, "msg": "Server %s would be deleted" % instance_id}
        delete_server(instance_id)
        return {"changed": True, "msg": "Server %s deleted" % instance_id}
    
    elif state == "present":
        changed = False
        if instance_id == None:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "Server would be created"}
            instance_id = create_server()
        else:
            res = ctx.run(
                ["curl", "-s", "-f", "-X", "GET", api_base_url + "/servers/" + instance_id],
                mutates=False
            )
        
        # Check if attributes need updating
        update_payload_lines = []
        has_updates = False
        
        # Name update
        if name != None:
            has_updates = True
        
        # IPv6 update
        if enable_ipv6 != None:
            has_updates = True
        
        # Security group update
        if security_group != None:
            has_updates = True
        
        # Public IP update
        if public_ip in ["dynamic", "allocated"]:
            has_updates = True
        
        if has_updates:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "Server attributes would be updated"}
            # Build simple update payload
            update_lines = []
            if name != None:
                update_lines.append("\"name\":\"" + name + "\"")
            if enable_ipv6 != None:
                update_lines.append("\"enable_ipv6\":" + str(enable_ipv6).lower())
            if security_group != None:
                update_lines.append("\"security_group\":{\"id\":\"" + security_group + "\"}")
            if public_ip in ["dynamic", "allocated"]:
                update_lines.append("\"dynamic_ip_required\":true")
            update_payload = "{" + ",".join(update_lines) + "}"
            update_server(instance_id, update_payload)
        
        return {"changed": changed, "msg": "Server ready"}
    
    elif state == "running":
        if instance_id == None:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "Server would be created and started"}
            instance_id = create_server()
        else:
            res = ctx.run(
                ["curl", "-s", "-f", "-X", "GET", api_base_url + "/servers/" + instance_id],
                mutates=False
            )
        
        current_state = fetch_state(instance_id)
        if current_state not in ["running", "starting"]:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "Server would be started"}
            start_server(instance_id)
        
        # Update attributes if needed
        update_lines = []
        if name != None:
            update_lines.append("\"name\":\"" + name + "\"")
        if enable_ipv6 != None:
            update_lines.append("\"enable_ipv6\":" + str(enable_ipv6).lower())
        if len(update_lines) > 0:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "Server attributes would be updated"}
            update_payload = "{" + ",".join(update_lines) + "}"
            update_server(instance_id, update_payload)
        
        return {"changed": changed, "msg": "Server running"}
    
    elif state == "stopped":
        if instance_id == None:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "Server would be created and stopped"}
            instance_id = create_server()
        else:
            res = ctx.run(
                ["curl", "-s", "-f", "-X", "GET", api_base_url + "/servers/" + instance_id],
                mutates=False
            )
        
        current_state = fetch_state(instance_id)
        if current_state != "stopped":
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "Server would be stopped"}
            stop_server(instance_id)
        
        # Update attributes if needed
        update_lines = []
        if name != None:
            update_lines.append("\"name\":\"" + name + "\"")
        if enable_ipv6 != None:
            update_lines.append("\"enable_ipv6\":" + str(enable_ipv6).lower())
        if len(update_lines) > 0:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "Server attributes would be updated"}
            update_payload = "{" + ",".join(update_lines) + "}"
            update_server(instance_id, update_payload)
        
        return {"changed": changed, "msg": "Server stopped"}
    
    elif state == "restarted":
        if instance_id == None:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "Server would be created and restarted"}
            instance_id = create_server()
        else:
            res = ctx.run(
                ["curl", "-s", "-f", "-X", "GET", api_base_url + "/servers/" + instance_id],
                mutates=False
            )
        
        changed = True
        if ctx.check_mode:
            return {"changed": True, "msg": "Server would be restarted"}
        
        # Restart regardless of current state
        restart_server(instance_id)
        
        # Update attributes if needed
        update_lines = []
        if name != None:
            update_lines.append("\"name\":\"" + name + "\"")
        if enable_ipv6 != None:
            update_lines.append("\"enable_ipv6\":" + str(enable_ipv6).lower())
        if len(update_lines) > 0:
            update_payload = "{" + ",".join(update_lines) + "}"
            update_server(instance_id, update_payload)
        
        return {"changed": True, "msg": "Server restarted"}
