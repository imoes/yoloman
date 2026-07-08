def main(ctx, params):
    # Extract parameters
    state = params.get("state", "present")
    auth_token = params.get("auth_token")
    name = params.get("name")
    private_network_id = params.get("private_network")
    description = params.get("description")
    network_address = params.get("network_address")
    subnet_mask = params.get("subnet_mask")
    datacenter = params.get("datacenter")
    add_members = params.get("add_members", [])
    remove_members = params.get("remove_members", [])
    wait = params.get("wait", True)
    wait_timeout = params.get("wait_timeout", 600)
    wait_interval = params.get("wait_interval", 5)

    # Validation
    if not auth_token:
        fail("auth_token parameter is required.")
    
    # Determine API URL
    api_url = params.get("api_url")
    if api_url == None:
        api_url = "https://cloud.1and1.com/v1"
    
    # Helper: perform curl request
    def oneandone_request(method, path, data_str):
        url = api_url + path
        args = ["curl", "-s", "-X", method, "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token]
        if data_str != "":
            args.extend(["-d", data_str])
        args.append(url)
        res = ctx.run(args)
        if res.rc != 0:
            fail("API call failed: " + res.stderr)
        return res.stdout

    # Helper: get network id by name (simple grep search)
    def find_network_id_by_name(net_name):
        if net_name == None:
            return None
        res = ctx.run(["curl", "-s", "-X", "GET", "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token, api_url + "/private_networks"])
        if res.rc != 0:
            return None
        out = res.stdout
        # Search for name match in JSON list
        lines = out.splitlines()
        for line in lines:
            if '"name"' in line and net_name in line:
                # Extract id — simple heuristic: look for id before name
                idx = line.find('"id":"')
                if idx != -1:
                    idx += 6
                    end = line.find('"', idx)
                    if end != -1:
                        return line[idx:end]
        return None

    # Resolve network id
    net_id = None
    if private_network_id != None:
        net_id = private_network_id
    elif name != None:
        net_id = find_network_id_by_name(name)

    # Helper: wait for network to be active
    def wait_for_active(nid, timeout, interval):
        elapsed = 0
        while elapsed < timeout:
            res = ctx.run(["curl", "-s", "-X", "GET", "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token, api_url + "/private_networks/" + nid])
            if res.rc == 0:
                if '"status"' in res.stdout and ('"ACTIVE"' in res.stdout or '"ON"' in res.stdout):
                    return True
            elapsed += interval
        fail("Wait timeout after %d seconds" % timeout)

    # Build minimal JSON for network creation/update
    def build_json(kv_list):
        body = "{"
        first = True
        for k, v in kv_list:
            if v != None:
                if not first:
                    body += ","
                first = False
                # Escape string value for JSON
                esc = ""
                for c in v:
                    if c == '"':
                        esc += '\\"'
                    elif c == '\\':
                        esc += '\\\\'
                    else:
                        esc += c
                body += '"' + k + '":"'
                body += esc
                body += '"'
        body += "}"
        return body

    # Main logic
    if state == "absent":
        if name == None:
            fail("'name' parameter is required for deleting a network.")
        if net_id == None:
            return {"changed": False, "msg": "Private network not found."}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete private network " + net_id}
        res = ctx.run(["curl", "-s", "-X", "DELETE", "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token, api_url + "/private_networks/" + net_id])
        if res.rc != 0:
            fail("Failed to delete private network: " + res.stderr)
        if wait:
            wait_for_active(net_id, wait_timeout, wait_interval)
        return {"changed": True, "msg": "Deleted private network " + net_id}

    elif state == "update":
        if net_id == None:
            fail("Private network not found.")
        if ctx.check_mode:
            # If any updates requested, predict change
            if description != None or network_address != None or subnet_mask != None or name != None or len(add_members) > 0 or len(remove_members) > 0:
                return {"changed": True, "msg": "would update private network " + net_id}
            return {"changed": False, "msg": "no updates needed"}

        changed = False

        # Update basic attributes
        updates = []
        if name != None:
            updates.append(("name", name))
        if description != None:
            updates.append(("description", description))
        if network_address != None:
            updates.append(("network_address", network_address))
        if subnet_mask != None:
            updates.append(("subnet_mask", subnet_mask))

        if len(updates) > 0:
            body = build_json(updates)
            res = ctx.run(["curl", "-s", "-X", "PATCH", "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token, "-d", body, api_url + "/private_networks/" + net_id])
            if res.rc != 0:
                fail("Failed to update network: " + res.stderr)
            changed = True

        # Add members
        if len(add_members) > 0:
            for member in add_members:
                # Assume member is server id
                attach_body = '{"server_id":"' + member + '"}'
                res = ctx.run(["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token, "-d", attach_body, api_url + "/private_networks/" + net_id + "/attach"])
                if res.rc != 0:
                    fail("Failed to attach server " + member + ": " + res.stderr)
            changed = True

        # Remove members
        if len(remove_members) > 0:
            for member in remove_members:
                detach_body = '{"server_id":"' + member + '"}'
                res = ctx.run(["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token, "-d", detach_body, api_url + "/private_networks/" + net_id + "/detach"])
                if res.rc != 0:
                    fail("Failed to detach server " + member + ": " + res.stderr)
            changed = True

        if wait and changed:
            wait_for_active(net_id, wait_timeout, wait_interval)

        return {"changed": changed, "msg": "Updated private network " + net_id}

    elif state == "present":
        if name == None:
            fail("'name' parameter is required for creating a new network.")
        if ctx.check_mode:
            return {"changed": True, "msg": "would create private network " + name}

        # Prepare creation payload
        kv_list = [("name", name)]
        if description != None:
            kv_list.append(("description", description))
        if network_address != None:
            kv_list.append(("network_address", network_address))
        if subnet_mask != None:
            kv_list.append(("subnet_mask", subnet_mask))
        if datacenter != None:
            kv_list.append(("datacenter_id", datacenter))

        body = build_json(kv_list)
        res = ctx.run(["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json", "-H", "X-Token: " + auth_token, "-d", body, api_url + "/private_networks"])
        if res.rc != 0:
            fail("Failed to create private network: " + res.stderr)

        # Parse id from response — simple heuristic
        out = res.stdout
        # Look for first id field
        idx = out.find('"id":"')
        if idx == -1:
            fail("No id found in creation response")
        idx += 6
        end = out.find('"', idx)
        if end == -1:
            fail("Invalid id in creation response")
        created_id = out[idx:end]

        if wait:
            wait_for_active(created_id, wait_timeout, wait_interval)

        return {"changed": True, "msg": "Created private network " + name, "data": {"id": created_id, "name": name}}

    else:
        fail("Unsupported state: " + state)
