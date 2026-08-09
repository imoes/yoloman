def main(ctx, params):
    action = params["action"]
    server_ip = params["server_ip"]
    username = params["username"]
    password = params["password"]
    network_id = params.get("network_id")
    ip_address = params.get("ip_address")
    network_name = params.get("network_name")
    network_family = params.get("network_family", "4")
    network_type = params.get("network_type", "lan")
    network_address = params.get("network_address")
    network_size = params.get("network_size")
    network_location = params.get("network_location", -1)

    base_url = "https://%s/rest/v1/" % server_ip

    def call_api(method, resource_url, stat_codes=None, params_dict=None, payload_data=None):
        stat_codes = stat_codes or [200]
        request_url = base_url + resource_url
        headers = ["Content-Type: application/json"]
        argv = ["curl", "-s", "-k", "-u", username + ":" + password, "-w", "\\n%{http_code}"]
        
        if method.lower() == "get":
            argv.extend(["-X", "GET"])
        elif method.lower() == "post":
            argv.extend(["-X", "POST"])
        elif method.lower() == "delete":
            argv.extend(["-X", "DELETE"])
        else:
            fail("unsupported HTTP method: " + method)
        
        if params_dict:
            query_str = ""
            for k, v in params_dict.items():
                if query_str:
                    query_str += "&"
                query_str += k + "=" + v
            request_url += "?" + query_str
        
        argv.append(request_url)
        
        if payload_data:
            argv.extend(["-d", payload_data])
        
        res = ctx.run(argv, mutates=(method.lower() != "get"), ok_codes=stat_codes)
        if res.skipped:
            return res.stdout
        if res.rc != 0 and 204 not in stat_codes:
            fail("API call failed: " + res.stderr)
        
        output = res.stdout
        lines = output.split("\n")
        if not lines:
            fail("empty API response")
        
        http_code = int(lines[-1])
        body = "\n".join(lines[:-1])
        
        if http_code == 204:
            return "Delete is done."
        return body

    def get_network(network_id_val=None, network_name_val=None, limit=1):
        if not network_id_val and not network_name_val:
            fail("You must specify one of the options 'network_name' or 'network_id'.")
        
        if network_id_val:
            response = call_api("GET", "networks/" + str(network_id_val))
        else:
            params_dict = {"query": "{\"name\":\"" + network_name_val + "\",\"type\":\"network\"}"}
            response = call_api("GET", "search", params_dict=params_dict)
            if response:
                parsed = []
                if response.startswith("["):
                    # Simple manual parsing for first object
                    depth = 0
                    start = -1
                    for i in range(len(response)):
                        c = response[i]
                        if c == "{":
                            if depth == 0:
                                start = i
                            depth += 1
                        elif c == "}":
                            depth -= 1
                            if depth == 0 and start != -1:
                                if len(parsed) == 0:
                                    parsed = [response[start:i+1]]
                                    break
                elif response.startswith("{"):
                    parsed = [response]
                if len(parsed) > 0 and limit == 1:
                    response = parsed[0]
                else:
                    response = ""
        return response

    def get_network_id(network_name_val="", network_type_val="lan"):
        if not network_name_val:
            fail("You must specify the option 'network_name'")
        params_dict = {"query": "{\"name\":\"" + network_name_val + "\",\"type\":\"network\"}"}
        response = call_api("GET", "search", params_dict=params_dict)
        if response.startswith("["):
            # Find first object's id
            depth = 0
            start = -1
            for i in range(len(response)):
                c = response[i]
                if c == "{":
                    if depth == 0:
                        start = i
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0 and start != -1:
                        obj = response[start:i+1]
                        # Extract id
                        id_key = '"id":'
                        pos = obj.find(id_key)
                        if pos != -1:
                            rest = obj[pos + len(id_key):].strip()
                            digits = ""
                            for ch in rest:
                                if ch.isdigit():
                                    digits += ch
                                else:
                                    break
                            if digits:
                                return digits
                        break
        return ""

    def reserve_next_available_ip(network_id_val=""):
        if not network_id_val:
            fail("You must specify the option 'network_id'.")
        response = call_api("POST", "networks/" + network_id_val + "/reserve_ip")
        if response:
            start = response.find("{")
            if start != -1:
                depth = 0
                for i in range(start, len(response)):
                    if response[i] == "{":
                        depth += 1
                    elif response[i] == "}":
                        depth -= 1
                        if depth == 0:
                            return response[start:i+1]
        return ""

    def release_ip(network_id_val="", ip_address_val=""):
        if not network_id_val or not ip_address_val:
            fail("You must specify both 'network_id' and 'ip_address'.")
        children = call_api("GET", "networks/" + network_id_val + "/children")
        ip_ids = []
        if children.startswith("["):
            depth = 0
            start = -1
            for i in range(len(children)):
                c = children[i]
                if c == "{":
                    if depth == 0:
                        start = i
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0 and start != -1:
                        obj = children[start:i+1]
                        # Extract id
                        id_key = '"id":'
                        pos = obj.find(id_key)
                        if pos != -1:
                            rest = obj[pos + len(id_key):].strip()
                            digits = ""
                            for ch in rest:
                                if ch.isdigit():
                                    digits += ch
                                else:
                                    break
                            if digits:
                                ip_ids.append(digits)
                        start = -1
        
        deleted_ip_id = ""
        for ip_id in ip_ids:
            ip_detail = call_api("GET", "ip_addresses/" + ip_id)
            if ip_detail:
                ip_key = '"address":'
                pos = ip_detail.find(ip_key)
                if pos != -1:
                    rest = ip_detail[pos + len(ip_key):].strip()
                    # Extract quoted string or value
                    if rest.startswith('"'):
                        end = rest.find('"', 1)
                        if end != -1 and rest[1:end] == ip_address_val:
                            deleted_ip_id = ip_id
                            break
                    elif rest.startswith(ip_address_val):
                        deleted_ip_id = ip_id
                        break
        
        if deleted_ip_id:
            call_api("DELETE", "ip_addresses/" + deleted_ip_id, stat_codes=[204])
        else:
            fail("Could not find IP address '" + ip_address_val + "' in network '" + network_id_val + "'.")
        return "Released IP " + ip_address_val + " from network " + network_id_val

    def delete_network(network_id_val=None, network_name_val=None):
        if not network_id_val and not network_name_val:
            fail("You must specify one of 'network_id' or 'network_name'.")
        if not network_id_val:
            network_id_val = get_network_id(network_name_val)
        call_api("DELETE", "networks/" + str(network_id_val), stat_codes=[204])
        return "Deleted network ID " + str(network_id_val)

    def reserve_network(
            network_id_val=None,
            reserved_network_name=None,
            reserved_network_size=None,
            reserved_network_family_val="4",
            reserved_network_type_val="lan",
            reserved_network_address=None):
        if not network_id_val or not reserved_network_name or not reserved_network_size:
            fail("You must specify 'network_id', 'reserved_network_name', and 'reserved_network_size'.")
        payload = {
            "network_name": reserved_network_name,
            "network_family": reserved_network_family_val,
            "network_type": reserved_network_type_val,
            "network_size": reserved_network_size,
            "network_location": int(network_id_val)
        }
        if reserved_network_address:
            payload["network_address"] = reserved_network_address
        payload_str = ""
        keys = sorted(payload.keys())
        payload_str += "{"
        for i in range(len(keys)):
            k = keys[i]
            v = payload[k]
            if i > 0:
                payload_str += ","
            payload_str += "\"" + k + "\":"
            if isinstance(v, int):
                payload_str += str(v)
            else:
                payload_str += "\"" + str(v) + "\""
        payload_str += "}"
        response = call_api(
            "POST",
            "networks/" + str(network_id_val) + "/reserve_network",
            stat_codes=[200, 201],
            payload_data=payload_str)
        return response

    def release_network(network_id_val=None, released_network_name=None, released_network_type_val="lan"):
        if not network_id_val or not released_network_name:
            fail("You must specify 'network_id' and 'released_network_name'.")
        children = call_api("GET", "networks/" + str(network_id_val) + "/children")
        matched_id = ""
        if children.startswith("["):
            depth = 0
            start = -1
            for i in range(len(children)):
                c = children[i]
                if c == "{":
                    if depth == 0:
                        start = i
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0 and start != -1:
                        obj = children[start:i+1]
                        # Extract nested network object
                        network_key = '"network":'
                        pos = obj.find(network_key)
                        if pos != -1:
                            rest = obj[pos + len(network_key):].strip()
                            if rest.startswith("{"):
                                depth2 = 0
                                net_start = -1
                                for j in range(len(rest)):
                                    if rest[j] == "{":
                                        if depth2 == 0:
                                            net_start = j
                                        depth2 += 1
                                    elif rest[j] == "}":
                                        depth2 -= 1
                                        if depth2 == 0 and net_start != -1:
                                            net_obj = rest[net_start:j+1]
                                            name_key = '"network_name":'
                                            npos = net_obj.find(name_key)
                                            if npos != -1:
                                                nrest = net_obj[npos + len(name_key):].strip()
                                                if nrest.startswith('"'):
                                                    end = nrest.find('"', 1)
                                                    if end != -1 and nrest[1:end] == released_network_name:
                                                        # Extract network_id
                                                        id_key = '"network_id":'
                                                        ipos = net_obj.find(id_key)
                                                        if ipos != -1:
                                                            irest = net_obj[ipos + len(id_key):].strip()
                                                            digits = ""
                                                            for ch in irest:
                                                                if ch.isdigit():
                                                                    digits += ch
                                                                else:
                                                                    break
                                                            if digits:
                                                                matched_id = digits
                                                        break
                                            break
                        start = -1
        
        if not matched_id:
            fail("Could not find network '" + released_network_name + "' under supernet '" + str(network_id_val) + "'.")
        call_api("DELETE", "networks/" + matched_id, stat_codes=[204])
        return "Released network '" + released_network_name + "'"

    def add_network(
            network_name_val=None,
            network_address_val=None,
            network_size_val=None,
            network_family_val="4",
            network_type_val="lan",
            network_location_val=-1):
        if not network_name_val or not network_address_val or not network_size_val:
            fail("You must specify 'network_name', 'network_address', and 'network_size'.")
        payload = {
            "network_name": network_name_val,
            "network_address": network_address_val,
            "network_size": network_size_val,
            "network_family": network_family_val,
            "network_type": network_type_val,
            "network_location": int(network_location_val)
        }
        payload_str = ""
        keys = sorted(payload.keys())
        payload_str += "{"
        for i in range(len(keys)):
            k = keys[i]
            v = payload[k]
            if i > 0:
                payload_str += ","
            payload_str += "\"" + k + "\":"
            if isinstance(v, int):
                payload_str += str(v)
            else:
                payload_str += "\"" + str(v) + "\""
        payload_str += "}"
        response = call_api("POST", "networks", stat_codes=[200], payload_data=payload_str)
        return response

    if action == "reserve_next_available_ip":
        if not network_id:
            fail("reserve_next_available_ip requires 'network_id'")
        result = reserve_next_available_ip(network_id)
        if not result:
            fail("reserve_next_available_ip failed")
        return {"changed": True, "msg": "Reserved IP address", "ip_info": result}

    elif action == "release_ip":
        if not network_id or not ip_address:
            fail("release_ip requires 'network_id' and 'ip_address'")
        result = release_ip(network_id, ip_address)
        return {"changed": True, "msg": result}

    elif action == "delete_network":
        result = delete_network(network_id, network_name)
        return {"changed": True, "msg": result}

    elif action == "get_network_id":
        if not network_name:
            fail("get_network_id requires 'network_name'")
        result = get_network_id(network_name, network_type)
        return {"changed": True, "msg": "Network ID retrieved", "network_id": result}

    elif action == "get_network":
        result = get_network(network_id, network_name)
        return {"changed": True, "msg": "Network details retrieved", "network_info": result}

    elif action == "reserve_network":
        if not network_id or not network_name or not network_size:
            fail("reserve_network requires 'network_id', 'network_name', and 'network_size'")
        result = reserve_network(
            network_id,
            network_name,
            network_size,
            network_family,
            network_type,
            network_address)
        return {"changed": True, "msg": "Network reserved", "network_info": result}

    elif action == "release_network":
        if not network_id or not network_name:
            fail("release_network requires 'network_id' and 'network_name'")
        result = release_network(network_id, network_name, network_type)
        return {"changed": True, "msg": result}

    elif action == "add_network":
        if not network_name or not network_address or not network_size:
            fail("add_network requires 'network_name', 'network_address', and 'network_size'")
        result = add_network(
            network_name,
            network_address,
            network_size,
            network_family,
            network_type,
            network_location)
        return {"changed": True, "msg": "Network added", "network_info": result}

    else:
        fail("Unsupported action: " + action)
