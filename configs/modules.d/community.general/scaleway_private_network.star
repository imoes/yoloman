def main(ctx, params):
    # Extract parameters
    name = params.get("name")
    project = params["project"]
    region = params["region"]
    tags = params.get("tags", [])
    state = params.get("state", "present")
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)

    # Map region to API endpoint for VPC
    region_map = {
        "ams1": "https://api.scaleway.com/vpc/v1/regions/ams1",
        "EMEA-NL-EVS": "https://api.scaleway.com/vpc/v1/regions/ams1",
        "par1": "https://api.scaleway.com/vpc/v1/regions/par1",
        "EMEA-FR-PAR1": "https://api.scaleway.com/vpc/v1/regions/par1",
        "par2": "https://api.scaleway.com/vpc/v1/regions/par2",
        "EMEA-FR-PAR2": "https://api.scaleway.com/vpc/v1/regions/par2",
        "waw1": "https://api.scaleway.com/vpc/v1/regions/waw1",
        "EMEA-PL-WAW1": "https://api.scaleway.com/vpc/v1/regions/waw1"
    }
    base_url = region_map.get(region)
    if base_url == None:
        fail("unsupported region: " + region)

    def make_request(method, path, data=None, params=None):
        url = base_url + "/" + path.lstrip("/")
        if params != None and len(params) > 0:
            query_parts = []
            for k in params.keys():
                query_parts.append(k + "=" + str(params[k]))
            url = url + "?" + "&".join(query_parts)

        # Prepare curl command
        curl_args = ["curl", "-s", "-X", method, "-H", "Authorization: Bearer " + api_token,
                     "-H", "Content-Type: application/json"]
        if data != None:
            curl_args.append("-d")
            curl_args.append(data)
        curl_args.append(url)

        # Determine if mutates
        mutates = (method != "GET")

        res = ctx.run(curl_args, mutates=mutates)
        return res

    def parse_json_field(data, field):
        key = '"' + field + '":'
        idx = data.find(key)
        if idx == -1:
            return None
        idx += len(key)
        # Handle string
        if data[idx] == '"':
            idx += 1
            end = idx
            while end < len(data) and data[end] != '"':
                end += 1
            return data[idx:end]
        # Handle array
        if data[idx] == '[':
            idx += 1
            arr = []
            while idx < len(data) and data[idx] != ']':
                while idx < len(data) and data[idx] in ' \t\n,':
                    idx += 1
                if idx >= len(data) or data[idx] != '"':
                    break
                idx += 1
                end = idx
                while end < len(data) and data[end] != '"':
                    end += 1
                arr.append(data[idx:end])
                idx = end + 1
            return arr
        # Handle number or null
        end = idx
        while end < len(data) and (data[end].isdigit() or data[end] in '-.'):
            end += 1
        val = data[idx:end]
        if val == "null":
            return None
        return val

    def parse_json_tags(data):
        key = '"tags":'
        idx = data.find(key)
        if idx == -1:
            return []
        idx += len(key)
        if data[idx] != '[':
            return []
        idx += 1
        arr = []
        while idx < len(data) and data[idx] != ']':
            while idx < len(data) and data[idx] in ' \t\n,':
                idx += 1
            if idx >= len(data) or data[idx] != '"':
                break
            idx += 1
            end = idx
            while end < len(data) and data[end] != '"':
                end += 1
            arr.append(data[idx:end])
            idx = end + 1
        return arr

    def get_private_network(name):
        page = 1
        page_size = 100
        while page <= 10:  # bound loops
            params = {
                "name": name,
                "order_by": "name_asc",
                "page": str(page),
                "page_size": str(page_size)
            }
            res = make_request("GET", "private-networks", params=params)
            if res.rc != 0:
                fail("failed to list private networks: " + res.stderr)
            data = res.stdout
            # Extract total_count
            total_count = 0
            idx = data.find('"total_count":')
            if idx != -1:
                idx += len('"total_count":')
                end = idx
                while end < len(data) and data[end].isdigit():
                    end += 1
                total_count = int(data[idx:end])
            # Extract networks array
            networks = []
            idx = data.find('"private_networks":[')
            if idx != -1:
                idx += len('"private_networks":[')
                depth = 1
                end = idx
                while end < len(data) and depth > 0:
                    if data[end] == '[':
                        depth += 1
                    elif data[end] == ']':
                        depth -= 1
                    end += 1
                arr_str = data[idx:end-1]
                # Split objects
                parts = []
                current = ""
                in_str = False
                escape = False
                for c in arr_str:
                    if escape:
                        current += c
                        escape = False
                    elif c == '\\':
                        current += c
                        escape = True
                    elif c == '"':
                        in_str = not in_str
                        current += c
                    elif c == '{' and not in_str:
                        current += c
                    elif c == '}' and not in_str:
                        current += c
                        parts.append(current)
                        current = ""
                    else:
                        current += c
                for p in parts:
                    p = p.strip()
                    if p:
                        networks.append(p)
            # Search for name
            for net_str in networks:
                if net_str.find('"name":"' + name + '"') != -1:
                    # Parse required fields
                    result = {}
                    result["id"] = parse_json_field(net_str, "id")
                    result["name"] = parse_json_field(net_str, "name")
                    result["project_id"] = parse_json_field(net_str, "project_id")
                    result["organization_id"] = parse_json_field(net_str, "organization_id")
                    result["tags"] = parse_json_tags(net_str)
                    result["created_at"] = parse_json_field(net_str, "created_at")
                    result["updated_at"] = parse_json_field(net_str, "updated_at")
                    result["zone"] = parse_json_field(net_str, "zone")
                    return result
            page += 1
            if page * page_size >= total_count:
                break
        return None

    if state == "present":
        if name == None:
            fail("name is required when state is present")

        current = get_private_network(name)
        desired_tags = tags

        if current != None:
            # Compare tags (order-insensitive)
            current_tags = current.get("tags", [])
            if sorted(current_tags) == sorted(desired_tags):
                return {"changed": False, "msg": "VPC %s already exists with correct tags" % name,
                        "scaleway_private_network": current}
            # Update required
            if ctx.check_mode:
                return {"changed": True, "msg": "would update VPC %s tags" % name}

            res = make_request("PATCH", "private-networks/" + current["id"],
                               data='{"name": "%s", "tags": %s}' % (name, str(desired_tags).replace("'", "\"")))
            if res.rc != 0:
                fail("failed to update VPC: " + res.stderr)
            data = res.stdout
            # Parse result
            result = {}
            result["id"] = parse_json_field(data, "id")
            result["name"] = parse_json_field(data, "name")
            result["project_id"] = parse_json_field(data, "project_id")
            result["organization_id"] = parse_json_field(data, "organization_id")
            result["tags"] = parse_json_tags(data)
            result["created_at"] = parse_json_field(data, "created_at")
            result["updated_at"] = parse_json_field(data, "updated_at")
            result["zone"] = parse_json_field(data, "zone")
            return {"changed": True, "msg": "updated VPC %s" % name,
                    "scaleway_private_network": result}
        else:
            # Create
            if ctx.check_mode:
                return {"changed": True, "msg": "would create VPC %s" % name}

            res = make_request("POST", "private-networks",
                               data='{"name": "%s", "project_id": "%s", "tags": %s}' % (name, project, str(desired_tags).replace("'", "\"")))
            if res.rc != 0:
                fail("failed to create VPC: " + res.stderr)
            data = res.stdout
            # Parse result
            result = {}
            result["id"] = parse_json_field(data, "id")
            result["name"] = parse_json_field(data, "name")
            result["project_id"] = parse_json_field(data, "project_id")
            result["organization_id"] = parse_json_field(data, "organization_id")
            result["tags"] = parse_json_tags(data)
            result["created_at"] = parse_json_field(data, "created_at")
            result["updated_at"] = parse_json_field(data, "updated_at")
            result["zone"] = parse_json_field(data, "zone")
            return {"changed": True, "msg": "created VPC %s" % name,
                    "scaleway_private_network": result}

    elif state == "absent":
        if name == None:
            fail("name is required when state is absent")
        current = get_private_network(name)
        if current == None:
            return {"changed": False, "msg": "VPC %s does not exist" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete VPC %s" % name}
        res = make_request("DELETE", "private-networks/" + current["id"])
        if res.rc != 0:
            fail("failed to delete VPC: " + res.stderr)
        return {"changed": True, "msg": "deleted VPC %s" % name}

    fail("unsupported state: " + state)
