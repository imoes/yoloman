def main(ctx, params):
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    node = params["node"]
    task_id = params.get("task")
    validate_certs = params.get("validate_certs", False)

    # Validate authentication method
    has_password = api_password != None
    has_token = api_token_id != None and api_token_secret != None
    if not has_password and not has_token:
        fail("one of api_password or api_token_id/api_token_secret is required")
    if has_token and (api_token_id == None or api_token_secret == None):
        fail("api_token_id and api_token_secret must be provided together")

    # Validate token-based auth requirement
    if has_token:
        auth_header = "PVEAPIToken=" + api_user + "!" + api_token_id + "=" + api_token_secret
    else:
        fail("password authentication is not supported in Starlark; use API token auth (api_token_id/api_token_secret)")

    # Build curl command
    if validate_certs == False:
        curl_opts = ["-k"]
    else:
        curl_opts = []

    base_url = "https://" + api_host + ":8006/api2/json"

    # Build request URL
    if task_id != None:
        url = base_url + "/nodes/" + node + "/tasks/" + task_id
        curl_cmd = ["curl"] + curl_opts + [
            "-s", "-X", "GET", "-H", "Authorization: " + auth_header,
            url
        ]
    else:
        url = base_url + "/nodes/" + node + "/tasks"
        curl_cmd = ["curl"] + curl_opts + [
            "-s", "-X", "GET", "-H", "Authorization: " + auth_header,
            url
        ]

    res = ctx.run(curl_cmd)
    if res.rc != 0:
        fail("failed to retrieve tasks from Proxmox: " + res.stderr)

    # Parse JSON manually
    stdout = res.stdout
    if not stdout.startswith("{\"data\":"):
        fail("unexpected API response format")

    # Strip outer structure: "{\"data\": ... }"
    idx = stdout.find("\"data\":") + len("\"data\":")
    json_data = stdout[idx:].strip()
    if json_data.startswith("{"):
        # Single task
        json_data = "[" + json_data + "]"
    if not json_data.startswith("["):
        fail("unexpected JSON structure in tasks response")

    # Parse list manually
    tasks = []
    content = json_data.strip()
    if len(content) < 2 or content[0] != '[' or content[-1] != ']':
        fail("malformed JSON array")

    inner = content[1:-1].strip()
    if inner == "":
        tasks = []
    else:
        # Split objects by top-level commas
        objects = []
        depth = 0
        current = ""
        in_string = False
        for c in inner:
            if c == '"' and not in_string:
                in_string = True
            elif c == '"' and in_string:
                in_string = False
            elif not in_string:
                if c == '{':
                    depth += 1
                elif c == '}':
                    depth -= 1
                elif c == ',' and depth == 0:
                    if current.strip() != "":
                        objects.append(current.strip())
                    current = ""
                    continue
            current += c
        if current.strip() != "":
            objects.append(current.strip())

        for obj_str in objects:
            if not (obj_str.startswith("{") and obj_str.endswith("}")):
                continue
            task = _parse_task_obj(obj_str)
            if task != None:
                tasks.append(task)

    return {"changed": False, "proxmox_tasks": tasks}


def _parse_task_obj(obj_str):
    result = {}
    s = obj_str[1:-1].strip()
    if s == "":
        return result

    parts = []
    depth = 0
    current = ""
    in_string = False
    i = 0
    while i < len(s):
        c = s[i]
        if c == '"' and (i == 0 or s[i-1] != '\\'):
            in_string = not in_string
        elif not in_string:
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
            elif c == ',' and depth == 0:
                parts.append(current.strip())
                current = ""
                i += 1
                continue
        current += c
        i += 1
    if current.strip() != "":
        parts.append(current.strip())

    for part in parts:
        if '=' not in part:
            continue
        eq_idx = part.find('=')
        key = part[:eq_idx].strip().strip('"')
        value = part[eq_idx+1:].strip()

        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
            result[key] = value
        else:
            # Try to parse as int
            parsed = True
            try_int = ""
            for ch in value:
                if ch >= '0' and ch <= '9' or ch == '-':
                    try_int = try_int + ch
                else:
                    parsed = False
                    break
            if parsed and len(try_int) == len(value):
                result[key] = int(try_int)
            else:
                result[key] = value

    # Handle 'status' -> 'failed' mapping
    if "status" in result:
        status = result["status"]
        if type(status) == "string":
            if status != "OK":
                result["failed"] = True
            else:
                result["failed"] = False

    return result
