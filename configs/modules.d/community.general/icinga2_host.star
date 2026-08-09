def main(ctx, params):
    state = params.get("state", "present")
    name = params["name"]
    zone = params.get("zone")
    template = params.get("template")
    check_command = params.get("check_command", "hostalive")
    display_name = params.get("display_name")
    if display_name == None:
        display_name = name
    ip = params.get("ip")
    variables = params.get("variables")
    url = params.get("url")
    
    if url == None:
        fail("url is required")
    
    base_url = url.rstrip("/")
    api_url = base_url + "/v1/objects/hosts/"

    templates = [template] if template else []
    attrs = {
        "address": ip,
        "display_name": display_name,
        "check_command": check_command,
        "zone": zone,
        "vars.made_by": "ansible"
    }
    if variables != None:
        for k, v in variables.items():
            attrs["vars." + k] = v

    data = {
        "templates": templates,
        "attrs": attrs
    }

    def build_curl_args(path, method, data_json):
        args = ["curl", "-s", "-X", method, "-H", "Accept: application/json", "-H", "Content-Type: application/json"]
        if params.get("url_username"):
            auth = params["url_username"]
            if params.get("url_password"):
                auth = auth + ":" + params["url_password"]
            args.extend(["-u", auth])
        if not params.get("validate_certs", True):
            args.append("-k")
        if params.get("client_cert"):
            args.extend(["--cert", params["client_cert"]])
        if params.get("client_key"):
            args.extend(["--key", params["client_key"]])
        args.append(api_url + path)
        if data_json != "":
            args.extend(["-d", data_json])
        return args

    def call_url(path, method="GET", data_json=""):
        args = build_curl_args(path, method, data_json)
        res = ctx.run(args)
        if res.rc != 0:
            fail("curl failed: " + res.stderr)
        return res.stdout.strip()

    def parse_json_simple(s):
        # Extract code
        code_start = s.find('"code":')
        code = 0
        if code_start != -1:
            code_str = s[code_start+7:]
            code_end = 0
            for i in range(len(code_str)):
                if code_str[i] not in "0123456789":
                    code_end = i
                    break
            if code_end > 0:
                code = int(code_str[:code_end].strip())
        
        # Extract data object - simplified parser
        data_start = s.find('"data":{')
        if data_start == -1:
            return {"code": code, "data": {}}
        
        # Find the closing brace of data object
        brace_count = 0
        start_idx = data_start + 7
        end_idx = start_idx
        for i in range(start_idx, len(s)):
            if s[i] == '{':
                brace_count += 1
            elif s[i] == '}':
                brace_count -= 1
                if brace_count == 0:
                    end_idx = i + 1
                    break
        
        data_str = s[start_idx:end_idx]
        return {"code": code, "data": parse_attrs_simple(data_str)}

    def parse_attrs_simple(s):
        result = {}
        # Skip braces
        if len(s) < 2:
            return result
        inner = s[1:-1]  # Remove outer { }
        if inner.strip() == "":
            return result
        
        # Simple key-value parsing for our specific format
        depth = 0
        key = ""
        value = ""
        in_key = False
        in_value = False
        i = 0
        while i < len(inner):
            c = inner[i]
            if c == '"' and not in_value:
                # Start key
                i += 1
                key = ""
                while i < len(inner) and inner[i] != '"':
                    key += inner[i]
                    i += 1
                # Skip closing quote and colon
                i += 1
                while i < len(inner) and inner[i] in " \t\n\r":
                    i += 1
                if i < len(inner) and inner[i] == ':':
                    i += 1
                while i < len(inner) and inner[i] in " \t\n\r":
                    i += 1
                # Value starts
                if i < len(inner) and inner[i] == '"':
                    i += 1
                    value = ""
                    in_value = True
                    while i < len(inner) and inner[i] != '"':
                        value += inner[i]
                        i += 1
                    if i < len(inner):
                        i += 1  # skip closing quote
                elif i < len(inner) and inner[i] == '{':
                    # Nested object
                    depth = 1
                    value = "{"
                    i += 1
                    while i < len(inner) and depth > 0:
                        if inner[i] == '{':
                            depth += 1
                        elif inner[i] == '}':
                            depth -= 1
                        value += inner[i]
                        i += 1
                else:
                    # Number or boolean
                    value = ""
                    while i < len(inner) and inner[i] not in [',', '}']:
                        value += inner[i]
                        i += 1
                
                result[key] = value
                in_value = False
            else:
                i += 1
        return result

    def host_exists():
        check_json = '{"filter": "match(\\"' + name + '\\", host.name)"}'
        res = call_url("hosts", "POST", check_json)
        parsed = parse_json_simple(res)
        results = parsed.get("data", {}).get("results", [])
        return len(results) >= 1

    def get_host():
        res = call_url(name, "GET")
        return parse_json_simple(res)

    def create_host():
        json_data = '{"templates": ' + str(templates).replace("'", '"') + ', "attrs": ' + str(attrs).replace("'", '"') + '}'
        json_data = json_data.replace("None", "null").replace("True", "true").replace("False", "false")
        res = call_url(name, "PUT", json_data)
        parsed = parse_json_simple(res)
        return parsed.get("code", 0) == 200

    def delete_host():
        delete_data = '{"cascade": 1}'
        res = call_url(name, "DELETE", delete_data)
        parsed = parse_json_simple(res)
        return parsed.get("code", 0) == 200

    def modify_host():
        modify_data = '{"attrs": ' + str(attrs).replace("'", '"') + '}'
        modify_data = modify_data.replace("None", "null").replace("True", "true").replace("False", "false")
        res = call_url(name, "POST", modify_data)
        parsed = parse_json_simple(res)
        return parsed.get("code", 0) == 200

    def needs_modification():
        if not host_exists():
            return False
        host_data = get_host()
        ic_results = host_data.get("data", {}).get("results", [])
        if len(ic_results) == 0:
            return False
        ic_attrs = ic_results[0].get("attrs", {})
        
        for key in attrs:
            if key not in ic_attrs:
                return True
            if str(attrs[key]) != str(ic_attrs.get(key)):
                return True
        return False

    exists = host_exists()

    if state == "present":
        if exists:
            if needs_modification():
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update " + name, "data": data}
                else:
                    if not modify_host():
                        fail("failed to modify host " + name)
                    return {"changed": True, "msg": "updated " + name, "data": data}
            else:
                return {"changed": False, "msg": name + " already exists with correct attributes", "data": data}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create " + name, "data": data}
            else:
                if not create_host():
                    fail("failed to create host " + name)
                return {"changed": True, "msg": "created " + name, "data": data}
    elif state == "absent":
        if exists:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete " + name, "data": data}
            else:
                if not delete_host():
                    fail("failed to delete host " + name)
                return {"changed": True, "msg": "deleted " + name, "data": data}
        else:
            return {"changed": False, "msg": name + " does not exist", "data": data}
