def main(ctx, params):
    region = params["region"]
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)
    query_parameters = params.get("query_parameters", {})

    # Map region to API endpoint
    region_map = {
        "ams1": "https://api.scaleway.com/instance/v1/zones/ams1",
        "EMEA-NL-EVS": "https://api.scaleway.com/instance/v1/zones/ams1",
        "par1": "https://api.scaleway.com/instance/v1/zones/par1",
        "EMEA-FR-PAR1": "https://api.scaleway.com/instance/v1/zones/par1",
        "par2": "https://api.scaleway.com/instance/v1/zones/par2",
        "EMEA-FR-PAR2": "https://api.scaleway.com/instance/v1/zones/par2",
        "waw1": "https://api.scaleway.com/instance/v1/zones/waw1",
        "EMEA-PL-WAW1": "https://api.scaleway.com/instance/v1/zones/waw1"
    }
    if region not in region_map:
        fail("unsupported region: " + region)
    
    api_endpoint = region_map[region]
    servers_url = api_endpoint + "/servers"

    # Build query parameters
    query_parts = []
    for k, v in query_parameters.items():
        query_parts.append(str(k) + "=" + str(v))
    if len(query_parts) > 0:
        servers_url = servers_url + "?" + "&".join(query_parts)

    # Perform GET request
    headers = {
        "Authorization": "Bearer " + api_token,
        "Content-Type": "application/json"
    }
    res = ctx.run(
        ["curl", "-sS", "-G", "--max-time", str(api_timeout), "--header", "Authorization: Bearer " + api_token, servers_url],
        mutates=False
    )

    if res.rc != 0:
        fail("failed to fetch servers: " + res.stderr)

    # Parse JSON manually (no json module available)
    # Expect response: {"servers": [...], ...}
    content = res.stdout
    if content.find('"servers"') == -1:
        fail("unexpected API response: missing 'servers' key")

    # Basic JSON parsing: extract servers list
    start = content.find('"servers"')
    if start == -1:
        fail("failed to parse servers list")
    start = content.find("[", start)
    if start == -1:
        fail("failed to find servers array")
    end = content.rfind("]")
    if end == -1 or end < start:
        fail("failed to parse servers array")

    servers_json = content[start:end + 1]

    # Convert to list (using a simple parser)
    servers = []
    level = 0
    current = ""
    in_string = False
    escape = False
    for i in range(len(servers_json)):
        c = servers_json[i]
        if not in_string:
            if c == '"':
                in_string = True
            elif c == '{':
                if level == 0:
                    current = ""
                level += 1
                current += c
                continue
            elif c == '}':
                level -= 1
                current += c
                if level == 0:
                    servers.append(current)
                continue
            elif c == '[' and level == 0:
                continue
            elif c == ']' and level == 0:
                continue
            elif c == ',' and level == 0:
                continue
            if level > 0:
                current += c
        else:
            if escape:
                escape = False
            elif c == '\\' and i + 1 < len(servers_json):
                escape = True
            elif c == '"':
                in_string = False
            current += c

    # Build result list (parse each server JSON manually)
    result_servers = []
    for s in servers:
        # Extract key fields using simple string search
        server_dict = {}
        # Extract 'id'
        id_start = s.find('"id"')
        if id_start != -1:
            val_start = s.find('"', id_start + 4) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['id'] = s[val_start:val_end]

        # Extract 'name'
        name_start = s.find('"name"')
        if name_start != -1:
            val_start = s.find('"', name_start + 6) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['name'] = s[val_start:val_end]

        # Extract 'state'
        state_start = s.find('"state"')
        if state_start != -1:
            val_start = s.find('"', state_start + 7) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['state'] = s[val_start:val_end]

        # Extract 'arch'
        arch_start = s.find('"arch"')
        if arch_start != -1:
            val_start = s.find('"', arch_start + 6) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['arch'] = s[val_start:val_end]

        # Extract 'boot_type'
        boot_start = s.find('"boot_type"')
        if boot_start != -1:
            val_start = s.find('"', boot_start + 11) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['boot_type'] = s[val_start:val_end]

        # Extract 'hostname'
        host_start = s.find('"hostname"')
        if host_start != -1:
            val_start = s.find('"', host_start + 10) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['hostname'] = s[val_start:val_end]

        # Extract 'private_ip'
        private_start = s.find('"private_ip"')
        if private_start != -1:
            val_start = s.find('"', private_start + 12) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['private_ip'] = s[val_start:val_end]

        # Extract 'commercial_type'
        type_start = s.find('"commercial_type"')
        if type_start != -1:
            val_start = s.find('"', type_start + 17) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['commercial_type'] = s[val_start:val_end]

        # Extract 'creation_date'
        date_start = s.find('"creation_date"')
        if date_start != -1:
            val_start = s.find('"', date_start + 15) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['creation_date'] = s[val_start:val_end]

        # Extract 'modification_date'
        mod_start = s.find('"modification_date"')
        if mod_start != -1:
            val_start = s.find('"', mod_start + 19) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['modification_date'] = s[val_start:val_end]

        # Extract 'state_detail'
        detail_start = s.find('"state_detail"')
        if detail_start != -1:
            val_start = s.find('"', detail_start + 14) + 1
            val_end = s.find('"', val_start)
            if val_start > 0 and val_end > val_start:
                server_dict['state_detail'] = s[val_start:val_end]

        # Extract 'tags'
        tags_start = s.find('"tags"')
        if tags_start != -1:
            list_start = s.find('[', tags_start)
            list_end = s.find(']', list_start)
            if list_start != -1 and list_end != -1:
                tags_str = s[list_start + 1:list_end]
                tags = []
                if len(tags_str.strip()) > 0:
                    for t in tags_str.split(','):
                        t_clean = t.strip().strip('"')
                        if len(t_clean) > 0:
                            tags.append(t_clean)
                server_dict['tags'] = tags

        # Extract 'public_ip'
        pub_start = s.find('"public_ip"')
        if pub_start != -1:
            obj_start = s.find('{', pub_start)
            if obj_start != -1:
                obj_end = s.find('}', obj_start)
                if obj_end != -1:
                    obj_str = s[obj_start:obj_end + 1]
                    ip_dict = {}
                    addr_start = obj_str.find('"address"')
                    if addr_start != -1:
                        val_start = obj_str.find('"', addr_start + 9) + 1
                        val_end = obj_str.find('"', val_start)
                        if val_start > 0 and val_end > val_start:
                            ip_dict['address'] = obj_str[val_start:val_end]
                    dyn_start = obj_str.find('"dynamic"')
                    if dyn_start != -1:
                        val_start = obj_str.find(':', dyn_start) + 1
                        val_end = obj_str.find(',', val_start)
                        if val_end == -1:
                            val_end = obj_str.find('}', val_start)
                        val = obj_str[val_start:val_end].strip()
                        ip_dict['dynamic'] = val == 'true'
                    server_dict['public_ip'] = ip_dict

        # Extract 'volumes'
        vol_start = s.find('"volumes"')
        if vol_start != -1:
            vol_dict = {}
            obj_start = s.find('{', vol_start)
            if obj_start != -1:
                # Find matching closing brace
                brace_count = 1
                vol_end = -1
                for i in range(obj_start + 1, len(s)):
                    if s[i] == '{':
                        brace_count += 1
                    elif s[i] == '}':
                        brace_count -= 1
                        if brace_count == 0:
                            vol_end = i
                            break
                if vol_end != -1:
                    vol_str = s[obj_start:vol_end + 1]
                    # Parse key-value pairs (simple approach: split by comma at top level)
                    level = 0
                    current_vol = ""
                    in_vol_string = False
                    escape_vol = False
                    for i in range(len(vol_str)):
                        c = vol_str[i]
                        if not in_vol_string:
                            if c == '"':
                                in_vol_string = True
                            elif c == '{':
                                level += 1
                                current_vol += c
                                continue
                            elif c == '}':
                                level -= 1
                                current_vol += c
                                if level == 0:
                                    # End of volumes dict
                                    break
                                continue
                            elif c == '[' and level == 1:
                                continue
                            elif c == ']' and level == 1:
                                continue
                            if level > 0:
                                current_vol += c
                        else:
                            if escape_vol:
                                escape_vol = False
                            elif c == '\\' and i + 1 < len(vol_str):
                                escape_vol = True
                            elif c == '"':
                                in_vol_string = False
                            current_vol += c
                    result_servers.append(server_dict)
                    continue

        result_servers.append(server_dict)

    return {"changed": False, "msg": "servers fetched successfully", "data": {"servers": result_servers}}
