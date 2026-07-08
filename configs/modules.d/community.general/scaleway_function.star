def main(ctx, params):
    # Required params
    name = params["name"]
    namespace_id = params["namespace_id"]
    region = params["region"]
    runtime = params["runtime"]
    state = params.get("state", "present")

    # Optional params with defaults
    description = params.get("description", "")
    min_scale = params.get("min_scale")
    max_scale = params.get("max_scale")
    memory_limit = params.get("memory_limit")
    function_timeout = params.get("function_timeout")
    handler = params.get("handler")
    privacy = params.get("privacy", "public")
    redeploy = params.get("redeploy", False)
    environment_variables = params.get("environment_variables", {})
    secret_environment_variables = params.get("secret_environment_variables", {})

    # Validate region
    valid_regions = ["fr-par", "nl-ams", "pl-waw"]
    if region not in valid_regions:
        fail("invalid region '%s'; must be one of: %s" % (region, ", ".join(valid_regions)))

    api_url = params.get("api_url", "https://api.scaleway.com")
    api_token = params["api_token"]
    api_timeout = params.get("api_timeout", 30)
    wait = params.get("wait", True)
    validate_certs = params.get("validate_certs", True)

    def build_curl_args(method, path, data_str):
        args = ["curl", "-sS", "-X", method, "-H", "Authorization: Bearer " + api_token]
        if not validate_certs:
            args.append("-k")
        if data_str != "":
            args.extend(["-H", "Content-Type: application/json", "-d", data_str])
        args.append(api_url + path)
        args.extend(["--max-time", str(int(api_timeout))])
        return args

    def parse_simple_json(raw):
        # Very basic parser for known fields only
        result = {}
        if raw.strip() == "" or raw.strip() == "null":
            return result
        # Split by top-level keys
        # Find all '"key":' and extract value
        i = 0
        while i < len(raw):
            # Find next quoted key
            quote = raw.find('"', i)
            if quote == -1:
                break
            key_start = quote + 1
            key_end = raw.find('"', key_start)
            if key_end == -1:
                break
            key = raw[key_start:key_end]
            # Skip whitespace and colon
            idx = key_end + 1
            while idx < len(raw) and raw[idx] in " \t\n\r":
                idx += 1
            if idx >= len(raw) or raw[idx] != ':':
                i = quote + 1
                continue
            idx += 1
            while idx < len(raw) and raw[idx] in " \t\n\r":
                idx += 1
            # Parse value
            if raw[idx] == '"':
                idx += 1
                val_start = idx
                while idx < len(raw) and raw[idx] != '"':
                    idx += 1
                val = raw[val_start:idx]
                result[key] = val
                i = idx + 1
            else:
                # number or null
                val_start = idx
                while idx < len(raw) and raw[idx] not in ",} \t\n\r":
                    idx += 1
                raw_val = raw[val_start:idx]
                if raw_val == "null":
                    result[key] = None
                elif raw_val.isdigit() or (raw_val.startswith('-') and raw_val[1:].isdigit()):
                    result[key] = int(raw_val)
                else:
                    result[key] = raw_val
                i = idx
        return result

    def list_functions():
        args = build_curl_args("GET", "/functions/v1beta1/regions/%s/functions" % region, "")
        res = ctx.run(args, mutates=False)
        if res.rc != 0:
            fail("failed to list functions: " + res.stderr)
        raw = res.stdout
        items = []
        # Extract list between "functions": [
        start = raw.find('"functions"')
        if start == -1:
            return items
        start = raw.find('[', start)
        if start == -1:
            return items
        # Find matching ]
        depth = 0
        end = -1
        for i in range(start, len(raw)):
            if raw[i] == '[':
                depth += 1
            elif raw[i] == ']':
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end == -1:
            return items
        list_str = raw[start+1:end].strip()
        if list_str == "":
            return items
        # Split by },{ — simple but works if no nested braces in strings
        parts = []
        seg = ""
        brace_depth = 0
        for c in list_str:
            if c == '{':
                brace_depth += 1
                seg += c
            elif c == '}':
                brace_depth -= 1
                seg += c
                if brace_depth == 0:
                    parts.append(seg.strip())
                    seg = ""
            else:
                seg += c
        for item in parts:
            fn = parse_simple_json(item)
            if fn.get("name") != None:
                items.append(fn)
        return items

    def get_function(fn_id):
        args = build_curl_args("GET", "/functions/v1beta1/regions/%s/functions/%s" % (region, fn_id), "")
        res = ctx.run(args, mutates=False)
        if res.rc != 0:
            fail("failed to get function %s: " % fn_id + res.stderr)
        return parse_simple_json(res.stdout)

    def create_function(data_str):
        args = build_curl_args("POST", "/functions/v1beta1/regions/%s/functions" % region, data_str)
        res = ctx.run(args, mutates=True)
        if res.rc != 0:
            fail("failed to create function: " + res.stderr)
        return parse_simple_json(res.stdout)

    def update_function(fn_id, data_str):
        args = build_curl_args("PATCH", "/functions/v1beta1/regions/%s/functions/%s" % (region, fn_id), data_str)
        res = ctx.run(args, mutates=True)
        if res.rc != 0:
            fail("failed to update function %s: " % fn_id + res.stderr)
        return parse_simple_json(res.stdout)

    def delete_function(fn_id):
        args = build_curl_args("DELETE", "/functions/v1beta1/regions/%s/functions/%s" % (region, fn_id), "")
        res = ctx.run(args, mutates=True)
        if res.rc != 0:
            fail("failed to delete function %s: " % fn_id + res.stderr)
        return {}

    # --- Main logic ---

    # Build payload
    payload = {
        "namespace_id": namespace_id,
        "name": name,
        "description": description,
        "min_scale": min_scale,
        "max_scale": max_scale,
        "runtime": runtime,
        "memory_limit": memory_limit,
        "timeout": function_timeout,
        "handler": handler,
        "privacy": privacy,
        "redeploy": redeploy,
        "environment_variables": environment_variables,
        "secret_environment_variables": secret_environment_variables
    }

    # Remove None values (using loop to avoid del)
    clean_payload = {}
    for k, v in payload.items():
        if v != None:
            clean_payload[k] = v
    payload = clean_payload

    # Convert to JSON-like string (simple)
    def dict_to_json_str(d):
        items = []
        for k, v in d.items():
            if type(v) == "string":
                items.append('"' + k + '": "' + v + '"')
            elif type(v) == "int" or type(v) == "NoneType":
                if v == None:
                    items.append('"' + k + '": null')
                else:
                    items.append('"' + k + '": ' + str(v))
            elif type(v) == "dict":
                items.append('"' + k + '": ' + str(v).replace("'", '"'))
            else:
                items.append('"' + k + '": "' + str(v) + '"')
        return "{" + ", ".join(items) + "}"

    # List functions
    functions = list_functions()
    fn_lookup = {}
    for fn in functions:
        n = fn.get("name")
        if n != None:
            fn_lookup[n] = fn

    if state == "absent":
        if name not in fn_lookup:
            return {"changed": False, "msg": "function %s does not exist" % name}
        target = fn_lookup[name]
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete function %s" % name}
        delete_function(target["id"])
        return {"changed": True, "msg": "deleted function %s" % name}

    # state == "present"
    if name not in fn_lookup:
        if ctx.check_mode:
            return {"changed": True, "msg": "would create function %s" % name}
        # Remove redeploy for creation
        if "redeploy" in payload:
            # Build new payload without redeploy
            new_payload = {}
            for k, v in payload.items():
                if k != "redeploy":
                    new_payload[k] = v
            payload = new_payload
        created = create_function(dict_to_json_str(payload))
        fn_id = created.get("id")
        if fn_id == None:
            fail("creation response missing id")
        return {"changed": True, "msg": "created function %s" % name, "function": get_function(fn_id)}

    # Update existing
    target = fn_lookup[name]

    # Build patch payload: only mutable, non-secret fields
    mutable_fields = ["description", "min_scale", "max_scale", "runtime", "memory_limit", "timeout", "handler", "privacy"]
    patch = {}
    for f in mutable_fields:
        if f in payload and payload.get(f) != None:
            current_val = target.get(f)
            if current_val != payload.get(f):
                patch[f] = payload.get(f)

    # Environment variables
    if "environment_variables" in payload:
        current_env = target.get("environment_variables")
        if str(current_env) != str(payload.get("environment_variables")):
            patch["environment_variables"] = payload.get("environment_variables")

    if len(patch) == 0:
        return {"changed": False, "msg": "function %s already correct" % name}

    if ctx.check_mode:
        return {"changed": True, "msg": "would update function %s" % name}

    # Perform update
    update_function(target["id"], dict_to_json_str(patch))
    return {"changed": True, "msg": "updated function %s" % name, "function": get_function(target["id"])}
