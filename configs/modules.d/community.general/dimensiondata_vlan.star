def main(ctx, params):
    # Extract parameters
    name = params["name"]
    description = params.get("description", "")
    network_domain = params["network_domain"]
    private_ipv4_base_address = params.get("private_ipv4_base_address", "")
    private_ipv4_prefix_size = params.get("private_ipv4_prefix_size", 0)
    state = params.get("state", "present")
    allow_expand = params.get("allow_expand", False)
    location = params["location"]
    region = params.get("region", "na")
    wait = params.get("wait", False)
    wait_poll_interval = params.get("wait_poll_interval", 2)
    wait_time = params.get("wait_time", 600)

    # Validate wait usage
    if wait and state != "present":
        fail("The wait parameter is only supported when state is 'present'.")

    # Build MCP URL and auth (simplified: use environment fallback handled externally)
    base_url = "https://cloudcontrol.dimensiondata.com/dd-" + region + "/" + location
    auth_header = "Basic " + ctx.facts().get("mcp_auth", "invalid")

    # Helper: run API call (no JSON module, parse manually)
    def api_request(path, method="GET", data_body=""):
        url = base_url + path
        # Build JSON body manually for POST/PUT
        body = ""
        if data_body == "":
            # Create body manually
            body = '{"name": "' + name + '", "description": "' + description + '", '
            body += '"privateIpv4RangeAddress": "' + private_ipv4_base_address + '", '
            body += '"privateIpv4RangeSize": ' + str(private_ipv4_prefix_size) + ' }'
        else:
            body = data_body
        # Build argv: no shell, so no pipes/redirects
        argv = ["curl", "-s", "-X", method, "-H", "Authorization: " + auth_header,
                "-H", "Content-Type: application/json", "-d", body, url]
        # Skip in check mode if mutating
        res = ctx.run(argv, mutates=(method in ["POST", "PUT", "DELETE"]))
        if res.rc != 0 and not res.skipped:
            fail("API request failed: " + res.stderr)
        return res

    # Get network_domain id
    def get_network_domain_id():
        res = api_request("/network/domain")
        # Parse JSON: look for network_domain by name
        text = res.stdout
        # Find networkDomains list
        start = text.find('"networkDomains"')
        if start == -1:
            fail("Unexpected API response: no networkDomains found")
        start_brace = text.find('[', start)
        if start_brace == -1:
            fail("Unexpected API response: no list in networkDomains")
        # Parse list manually
        pos = start_brace + 1
        while pos < len(text):
            while pos < len(text) and text[pos] in " \t\n\r":
                pos += 1
            if pos >= len(text) or text[pos] == ']':
                break
            obj_start = text.find('{', pos)
            if obj_start == -1:
                break
            brace_count = 1
            end = obj_start + 1
            while end < len(text) and brace_count > 0:
                if text[end] == '{':
                    brace_count += 1
                elif text[end] == '}':
                    brace_count -= 1
                end += 1
            obj_str = text[obj_start:end]
            # Extract id and name
            id_val = ""
            name_val = ""
            for key in ["id", "name"]:
                i = obj_str.find('"' + key + '"')
                if i != -1:
                    colon = obj_str.find(':', i)
                    if colon != -1:
                        q1 = obj_str.find('"', colon)
                        q2 = obj_str.find('"', q1 + 1)
                        if q1 != -1 and q2 != -1:
                            val = obj_str[q1 + 1:q2]
                            if key == "id":
                                id_val = val
                            else:
                                name_val = val
            if id_val and name_val:
                if name_val == network_domain or id_val == network_domain:
                    return id_val
            pos = end
        fail("Network domain not found: " + network_domain)

    # Get VLAN info by name
    def get_vlan(network_domain_id):
        res = api_request("/network/vlan?networkDomainId=" + network_domain_id)
        text = res.stdout
        # Find vlans list
        start = text.find('"vlans"')
        if start == -1:
            fail("Unexpected API response: no vlans found")
        start_brace = text.find('[', start)
        if start_brace == -1:
            fail("Unexpected API response: no list in vlans")
        pos = start_brace + 1
        while pos < len(text):
            while pos < len(text) and text[pos] in " \t\n\r":
                pos += 1
            if pos >= len(text) or text[pos] == ']':
                break
            obj_start = text.find('{', pos)
            if obj_start == -1:
                break
            brace_count = 1
            end = obj_start + 1
            while end < len(text) and brace_count > 0:
                if text[end] == '{':
                    brace_count += 1
                elif text[end] == '}':
                    brace_count -= 1
                end += 1
            obj_str = text[obj_start:end]
            # Extract name and id
            name_val = ""
            id_val = ""
            ipv4_addr = ""
            ipv4_size = 0
            ipv4_gateway = ""
            status = ""
            for key in ["name", "id", "privateIpv4RangeAddress", "privateIpv4RangeSize", "ipv4Gateway", "status"]:
                i = obj_str.find('"' + key + '"')
                if i != -1:
                    colon = obj_str.find(':', i)
                    if colon != -1:
                        q1 = obj_str.find('"', colon)
                        q2 = obj_str.find('"', q1 + 1)
                        if q1 != -1 and q2 != -1:
                            val = obj_str[q1 + 1:q2]
                            if key == "name":
                                name_val = val
                            elif key == "id":
                                id_val = val
                            elif key == "privateIpv4RangeAddress":
                                ipv4_addr = val
                            elif key == "privateIpv4RangeSize":
                                ipv4_size = int(val)
                            elif key == "ipv4Gateway":
                                ipv4_gateway = val
                            elif key == "status":
                                status = val
            if name_val == name:
                return {
                    "id": id_val,
                    "name": name_val,
                    "description": description,
                    "private_ipv4_range_address": ipv4_addr,
                    "private_ipv4_range_size": ipv4_size,
                    "ipv4_gateway": ipv4_gateway,
                    "status": status
                }
            pos = end
        return None

    # Wait for VLAN state (simplified polling)
    def wait_for_vlan(vlan_id, desired_state):
        elapsed = 0
        while elapsed < wait_time:
            vlan = get_vlan(network_domain_id)
            if vlan and vlan["status"] == desired_state:
                return vlan
            if ctx.check_mode:
                return vlan
            # Simulate polling by doing read-only probe
            elapsed += wait_poll_interval
        fail("Timeout waiting for VLAN state change")

    # Main logic
    network_domain_id = get_network_domain_id()
    vlan = get_vlan(network_domain_id)

    if state == "present":
        if vlan == None:
            # Create VLAN
            if ctx.check_mode:
                return {"changed": True, "msg": "would create VLAN " + name + " in network domain " + network_domain}
            res = api_request("/network/vlan", "POST", "")
            # Extract created vlan id from response
            created_id = ""
            id_pos = res.stdout.find('"id"')
            if id_pos != -1:
                colon = res.stdout.find(':', id_pos)
                if colon != -1:
                    q1 = res.stdout.find('"', colon)
                    q2 = res.stdout.find('"', q1 + 1)
                    if q1 != -1 and q2 != -1:
                        created_id = res.stdout[q1 + 1:q2]
            if wait and created_id:
                vlan = wait_for_vlan(created_id, "NORMAL")
            else:
                vlan = get_vlan(network_domain_id)
            return {"changed": True, "msg": "Created VLAN " + name + " in network domain " + network_domain}
        else:
            # Check differences
            if private_ipv4_base_address and vlan["private_ipv4_range_address"] != private_ipv4_base_address:
                fail("Cannot change the private IPv4 base address for an existing VLAN.")
            if private_ipv4_prefix_size > 0:
                current_size = vlan["private_ipv4_range_size"]
                if private_ipv4_prefix_size < current_size:
                    if not allow_expand:
                        fail("The configured private IPv4 network size (" + str(private_ipv4_prefix_size) +
                             "-bit prefix) differs from current (" + str(current_size) +
                             "-bit prefix) and needs expansion. Use allow_expand=true.")
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would expand VLAN " + name}
                    res = api_request("/network/vlan/" + vlan["id"], "PUT", "")
                    if wait:
                        vlan = wait_for_vlan(vlan["id"], "NORMAL")
                    return {"changed": True, "msg": "Expanded VLAN " + name}
                elif private_ipv4_prefix_size > current_size:
                    fail("Cannot shrink the private IPv4 network for an existing VLAN.")
            # Check name/description changes
            needs_update = False
            if description != vlan["description"] or name != vlan["name"]:
                needs_update = True
            if ctx.check_mode and needs_update:
                return {"changed": True, "msg": "would update VLAN " + name}
            if needs_update:
                res = api_request("/network/vlan/" + vlan["id"], "PUT", "")
                if wait:
                    vlan = wait_for_vlan(vlan["id"], "NORMAL")
                return {"changed": True, "msg": "Updated VLAN " + name}
            return {"changed": False, "msg": "VLAN " + name + " is already present and up to date"}

    elif state == "readonly":
        if vlan == None:
            fail("VLAN " + name + " does not exist in network domain " + network_domain)
        return {"changed": False, "msg": "Read VLAN " + name, "data": vlan}

    elif state == "absent":
        if vlan == None:
            return {"changed": False, "msg": "VLAN " + name + " is absent from network domain " + network_domain}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete VLAN " + name}
        res = api_request("/network/vlan/" + vlan["id"], "DELETE", "")
        if wait:
            elapsed = 0
            while elapsed < wait_time:
                vlan_check = get_vlan(network_domain_id)
                if vlan_check == None:
                    break
                if ctx.check_mode:
                    break
                elapsed += wait_poll_interval
        return {"changed": True, "msg": "Deleted VLAN " + name}

    fail("Unsupported state: " + state)
