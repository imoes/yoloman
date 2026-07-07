def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    location = params["location"]
    description = params.get("description")
    mcp_user = params.get("mcp_user")
    mcp_password = params.get("mcp_password")
    region = params.get("region", "na")
    service_plan = params.get("service_plan", "ESSENTIALS")
    validate_certs = params.get("validate_certs", True)
    wait = params.get("wait", False)
    wait_poll_interval = params.get("wait_poll_interval", 2)
    wait_time = params.get("wait_time", 600)

    if validate_certs == False:
        fail("validate_certs=False is not supported in Starlark")

    mcp_version = "2.0"
    if mcp_user == None or mcp_password == None:
        mcp_version = "1.0"

    region_prefix = "dd-" + region
    endpoint = "https://" + region_prefix + ".dimensiondata.com/api/v1"

    auth_header = ""
    if mcp_user != None and mcp_password != None:
        auth_str = mcp_user + ":" + mcp_password
        encoded = ""
        b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        # Manual base64 encoding
        i = 0
        while i < len(auth_str):
            c1 = ord(auth_str[i])
            i = i + 1
            c2 = 0
            if i < len(auth_str):
                c2 = ord(auth_str[i])
                i = i + 1
            c3 = 0
            if i < len(auth_str):
                c3 = ord(auth_str[i])
                i = i + 1

            b1 = c1 >> 2
            b2 = ((c1 & 3) << 4) | (c2 >> 4)
            b3 = ((c2 & 15) << 2) | (c3 >> 6)
            b4 = c3 & 63

            encoded = encoded + b64_chars[b1] + b64_chars[b2]
            if i - 2 < len(auth_str):
                encoded = encoded + b64_chars[b3]
            else:
                encoded = encoded + "="
            if i - 1 < len(auth_str):
                encoded = encoded + b64_chars[b4]
            else:
                encoded = encoded + "="

        auth_header = "Basic " + encoded

    def api_request(path, method="GET", data=""):
        url = endpoint + path
        headers = ["-H", "Content-Type: application/json"]
        if auth_header != "":
            headers = headers + ["-H", "Authorization: " + auth_header]
        cmd = ["curl", "-s", "-X", method] + headers + [url]
        if data != "":
            cmd = cmd + ["--data", data]
        res = ctx.run(cmd, mutates=(method != "GET"))
        if res.rc != 0:
            fail("API request failed: " + res.stderr)
        return res

    def parse_json(s):
        # Minimal JSON parser for flat dict of strings/int/bool/null
        s = s.strip()
        if s == "":
            return {}
        if s[0] != '{':
            return None
        result = {}
        s = s[1:]
        while True:
            s = s.strip()
            if s == "" or s[0] == '}':
                break
            # expect "key"
            if s[0] != '"':
                break
            s = s[1:]
            key = ""
            while s != "" and s[0] != '"':
                key = key + s[0]
                s = s[1:]
            if s == "" or s[0] != '"':
                break
            s = s[1:].strip()
            if s == "" or s[0] != ':':
                break
            s = s[1:].strip()
            # expect value
            value = ""
            if s[0] == '"':
                s = s[1:]
                while s != "" and s[0] != '"':
                    value = value + s[0]
                    s = s[1:]
                s = s[1:]
            elif s.startswith("true"):
                value = "true"
                s = s[4:]
            elif s.startswith("false"):
                value = "false"
                s = s[5:]
            elif s.startswith("null"):
                value = "null"
                s = s[4:]
            else:
                # numeric
                while s != "" and (s[0].isdigit() or s[0] == '-' or s[0] == '.'):
                    value = value + s[0]
                    s = s[1:]
            result[key] = value
            s = s.strip()
            if s == "" or s[0] != ',':
                break
            s = s[1:]
        return result

    def get_network():
        res = api_request("/network?location=" + location)
        netlist = parse_json(res.stdout)
        if netlist == None:
            fail("Failed to parse network list: " + res.stdout)
        networks = []
        if netlist.get("network") != None:
            networks = netlist["network"]
        if type(networks) == type(""):
            networks = [networks]
        for net in networks:
            if type(net) == type(""):
                continue
            if net.get("name") == name:
                return net
        return None

    def network_to_dict(net):
        d = {
            "id": net.get("id", ""),
            "name": net.get("name", ""),
            "description": net.get("description", ""),
            "location": net.get("location", location),
            "status": net.get("status", "null")
        }
        if mcp_version == "1.0":
            d["private_net"] = net.get("privateNet", "")
            d["multicast"] = net.get("multicast", "false")
        else:
            d["private_net"] = ""
            d["multicast"] = ""
        return d

    if state == "present":
        network = get_network()
        if network != None:
            return {"changed": False, "msg": "Network already exists", "data": {"network": network_to_dict(network)}}

        if mcp_version == "1.0":
            data = '{"name": "' + name + '", "description": "' + (description or "") + '"}'
            res = api_request("/network?location=" + location, method="POST", data=data)
            created = parse_json(res.stdout)
        else:
            data = '{"name": "' + name + '", "description": "' + (description or "") + '", "servicePlan": "' + service_plan + '"}'
            res = api_request("/networkDomain?location=" + location, method="POST", data=data)
            created = parse_json(res.stdout)

        return {"changed": True, "msg": "Created network " + name, "data": {"network": network_to_dict(created)}}

    elif state == "absent":
        network = get_network()
        if network == None:
            return {"changed": False, "msg": "Network does not exist"}

        if mcp_version == "1.0":
            res = api_request("/network/" + network["id"] + "?location=" + location, method="DELETE")
        else:
            res = api_request("/networkDomain/" + network["id"] + "?location=" + location, method="DELETE")

        if res.rc != 0:
            fail("Failed to delete network")

        return {"changed": True, "msg": "Deleted network " + name}

    else:
        fail("Unsupported state: " + state)
