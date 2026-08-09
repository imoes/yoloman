def main(ctx, params):
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    storage = params.get("storage")
    stype = params.get("type")
    validate_certs = params.get("validate_certs", False)

    # Token auth requires both token_id and token_secret
    if api_token_id != None:
        if api_token_secret == None:
            fail("api_token_id requires api_token_secret")
    elif api_password == None:
        fail("One of api_password or api_token_id must be provided")

    # Validate mutually exclusive options
    if storage != None and stype != None:
        fail("storage and type are mutually exclusive")

    # Build base URL for Proxmox API
    scheme = "https"
    base_url = "%s://%s:8006/api2/json" % (scheme, api_host)

    # Construct auth header
    if api_token_id != None:
        auth_header = "PVEAPIToken=%s@%s=%s" % (api_user, api_token_id, api_token_secret)
    else:
        auth_header = "PVEAuthCookie=" + api_password

    # Helper to make HTTP requests (using curl)
    def http_get(path, params_dict=None):
        url = base_url + path
        args = ["curl", "-sS", "-k" if not validate_certs else "-k", "-H", "Authorization: " + auth_header, url]
        if params_dict != None:
            for k, v in params_dict.items():
                args.append("%s=%s" % (k, str(v).lower() if type(v) == "bool" else str(v)))
        res = ctx.run(args)
        if res.rc != 0:
            fail("HTTP GET %s failed: %s" % (url, res.stderr))
        return res.stdout

    # Safe string-to-number check without try/except
    def is_number_string(s):
        s = s.strip()
        if s == "":
            return False
        # Handle integers (optionally with sign)
        if s.startswith("-") or s.startswith("+"):
            s = s[1:]
        if s.isdigit():
            return True
        # Handle floats
        if s.find(".") != -1:
            parts = s.split(".")
            if len(parts) == 2:
                return parts[0].isdigit() and (parts[1].isdigit() if parts[1] != "" else False)
            elif len(parts) == 3:  # Could have exponent
                return False
        return False

    # Parse JSON manually (no json module)
    def parse_json(text):
        text = text.strip()
        if text == "null":
            return None
        if text.startswith("["):
            return parse_json_list(text)
        if text.startswith("{"):
            return parse_json_object(text)
        # String or bool literal
        if text.startswith('"'):
            return parse_json_string(text)
        if text == "true":
            return True
        if text == "false":
            return False
        # Number literal
        if is_number_string(text):
            if text.find(".") != -1:
                return float(text)
            else:
                return int(text)
        return text

    def parse_json_string(text):
        text = text.strip()
        if not (text.startswith('"') and text.endswith('"')):
            fail("Invalid JSON string: %s" % text)
        return text[1:-1].replace('\\"', '"').replace('\\\\', '\\')

    def parse_json_object(text):
        text = text.strip()
        if not (text.startswith("{") and text.endswith("}")):
            fail("Invalid JSON object: %s" % text)
        inner = text[1:-1].strip()
        if inner == "":
            return {}
        result = {}
        level = 0
        current_key = ""
        current_value = ""
        in_key = True
        i = 0
        while i < len(inner):
            c = inner[i]
            if c == '"' and (i == 0 or inner[i-1] != '\\'):
                # Handle quoted string
                end = i + 1
                while end < len(inner) and (inner[end] != '"' or (end > 0 and inner[end-1] == '\\')):
                    end += 1
                if end >= len(inner):
                    fail("Unmatched quote in JSON")
                token = inner[i:end+1]
                if in_key:
                    current_key = token
                else:
                    current_value = token
                i = end + 1
                continue
            elif c == '{':
                level += 1
            elif c == '}':
                level -= 1
            elif c == '[':
                level += 1
            elif c == ']':
                level -= 1
            elif c == ',' and level == 0:
                if in_key and current_value != "":
                    fail("Malformed JSON: expected value after colon")
                if current_key != "":
                    key = parse_json_string(current_key.strip())
                    result[key] = parse_json(current_value.strip())
                current_key = ""
                current_value = ""
                in_key = True
                i += 1
                continue
            elif c == ':' and level == 0:
                in_key = False
                i += 1
                continue
            else:
                if in_key:
                    current_key += c
                else:
                    current_value += c
            i += 1

        # Final key-value pair
        if current_key != "":
            key = parse_json_string(current_key.strip())
            result[key] = parse_json(current_value.strip())

        return result

    def parse_json_list(text):
        text = text.strip()
        if not (text.startswith("[") and text.endswith("]")):
            fail("Invalid JSON list: %s" % text)
        inner = text[1:-1].strip()
        if inner == "":
            return []
        result = []
        level = 0
        current_value = ""
        i = 0
        while i < len(inner):
            c = inner[i]
            if c == '"' and (i == 0 or inner[i-1] != '\\'):
                # Handle quoted string
                end = i + 1
                while end < len(inner) and (inner[end] != '"' or (end > 0 and inner[end-1] == '\\')):
                    end += 1
                if end >= len(inner):
                    fail("Unmatched quote in JSON")
                token = inner[i:end+1]
                current_value += token
                i = end + 1
                continue
            elif c == '{':
                level += 1
            elif c == '}':
                level -= 1
            elif c == '[':
                level += 1
            elif c == ']':
                level -= 1
            elif c == ',' and level == 0:
                if current_value.strip() != "":
                    result.append(parse_json(current_value.strip()))
                current_value = ""
                i += 1
                continue
            else:
                current_value += c
            i += 1

        if current_value.strip() != "":
            result.append(parse_json(current_value.strip()))

        return result

    # Fetch storages
    if storage != None:
        json_output = http_get("/storage/" + storage, {})
        data = parse_json(json_output).get("data")
        if data == None:
            fail("Storage '%s' does not exist" % storage)
        storages = [data]
    else:
        query_params = {}
        if stype != None:
            query_params["type"] = stype
        json_output = http_get("/storage", query_params)
        data_list = parse_json(json_output)
        if type(data_list) != "dict":
            fail("Unexpected response format for storage listing")
        storages = data_list.get("data", [])

    # Process each storage record
    def transform_storage(s):
        res = {}
        for k, v in s.items():
            if k == "shared" and type(v) == "string":
                res["shared"] = v.lower() == "true"
            elif k == "content" and type(v) == "string":
                res["content"] = v.split(",") if v != "" else []
            elif k == "nodes" and type(v) == "string":
                res["nodes"] = v.split(",") if v != "" else []
            elif k == "prune-backups" and type(v) == "string":
                if v == "":
                    res["prune-backups"] = {}
                else:
                    options = v.split(",")
                    pb = {}
                    for opt in options:
                        parts = opt.split("=")
                        if len(parts) == 2:
                            pb[parts[0]] = parts[1]
                    res["prune-backups"] = pb
            else:
                res[k] = v
        return res

    transformed_storages = []
    for s in storages:
        transformed_storages.append(transform_storage(s))

    return {"changed": False, "msg": "Retrieved storage information", "data": {"proxmox_storages": transformed_storages}}
