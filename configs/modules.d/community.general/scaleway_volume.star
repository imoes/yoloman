def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    project = params.get("project")
    organization = params.get("organization")
    size = params.get("size")
    volume_type = params.get("volume_type")
    region = params["region"]
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)

    # Map region to API endpoint (simplified version of SCALEWAY_LOCATION)
    region_map = {
        "ams1": "https://api.scaleway.com",
        "par1": "https://api.scaleway.com",
        "par2": "https://api.scaleway.com",
        "waw1": "https://api.scaleway.com",
        "EMEA-NL-EVS": "https://api.scaleway.com",
        "EMEA-FR-PAR1": "https://api.scaleway.com",
        "EMEA-FR-PAR2": "https://api.scaleway.com",
        "EMEA-PL-WAW1": "https://api.scaleway.com"
    }
    if region not in region_map:
        fail("Unsupported region: " + region)

    # Determine project ID (project takes precedence over organization)
    if project == None and organization == None:
        fail("One of project or organization is required")
    if project != None and organization != None:
        fail("Only one of project or organization can be specified")
    if project == None:
        project = organization

    # Build API headers
    headers = {
        "X-Auth-Token": api_token,
        "Content-Type": "application/json"
    }

    # Helper to call API
    def api_call(method, path, payload=None, ok_codes=[0, 200, 201, 204]):
        url = api_url.rstrip("/") + path
        # Build curl args manually (no shell)
        curl_args = ["curl", "-s", "-w", "\\n%{http_code}", "-X", method.upper()]
        for key, value in headers.items():
            curl_args.extend(["-H", key + ": " + value])
        if payload != None:
            # Simple JSON string (no fancy escaping)
            json_str = '{'
            items = list(payload.items())
            for i, (k, v) in enumerate(items):
                if i > 0:
                    json_str += ", "
                # Basic escaping for strings; assume keys are safe
                if type(v) == "string":
                    escaped = v.replace("\\", "\\\\").replace('"', '\\"')
                    json_str += '"' + k + '": "' + escaped + '"'
                elif type(v) == "int":
                    json_str += '"' + k + '": ' + str(v)
                elif v == None:
                    json_str += '"' + k + '": null'
                else:
                    fail("Unsupported payload value type: " + type(v))
            json_str += '}'
            curl_args.extend(["-d", json_str])
        if not validate_certs:
            curl_args.append("-k")
        # Timeout is optional, omit if 0
        if api_timeout > 0:
            curl_args.extend(["--max-time", str(int(api_timeout))])
        curl_args.append(url)
        res = ctx.run(curl_args)
        if res.skipped:
            return {"skipped": True, "rc": res.rc, "stdout": res.stdout, "stderr": res.stderr, "headers": headers}
        if res.rc != 0:
            fail("API call failed with rc=" + str(res.rc) + ": " + res.stderr)
        # Parse response: last line is HTTP code, rest is body
        lines = res.stdout.strip().split("\n")
        if len(lines) < 2:
            body = res.stdout.strip()
            code = "0"
        else:
            code = lines[-1].strip()
            body = "\n".join(lines[:-1])
        return {"skipped": False, "rc": res.rc, "body": body, "code": int(code)}

    # Get volume list
    vol_list = api_call("GET", "/volumes")
    if vol_list.get("skipped"):
        fail("API call skipped (check_mode)")
    if vol_list["code"] != 200:
        fail("Failed to list volumes: HTTP " + str(vol_list["code"]) + ", " + vol_list["body"])

    # Parse volumes list (simple JSON parsing without json module)
    volumes_raw = vol_list["body"]
    vol_start = volumes_raw.find('"volumes"')
    if vol_start == -1:
        fail("Malformed volumes list: no 'volumes' key found")
    bracket_start = volumes_raw.find("[", vol_start)
    if bracket_start == -1:
        fail("Malformed volumes list: no array found")
    # Find matching bracket — simple linear scan (safe for small arrays)
    depth = 0
    bracket_end = bracket_start
    for i in range(bracket_start, len(volumes_raw)):
        c = volumes_raw[i]
        if c == '[':
            depth += 1
        elif c == ']':
            depth -= 1
            if depth == 0:
                bracket_end = i
                break
    if depth != 0:
        fail("Malformed volumes list: unmatched brackets")
    arr_str = volumes_raw[bracket_start:bracket_end + 1]

    # Parse simple array of objects (assumes no nested arrays/objects beyond depth 1)
    volumes = []
    idx = 0
    while idx < len(arr_str):
        # Find next '{'
        obj_start = arr_str.find("{", idx)
        if obj_start == -1:
            break
        # Find matching '}' — again, simple depth scan
        d = 0
        for i in range(obj_start, len(arr_str)):
            c = arr_str[i]
            if c == '{':
                d += 1
            elif c == '}':
                d -= 1
                if d == 0:
                    obj_str = arr_str[obj_start:i+1]
                    # Parse key-value pairs manually (naive but sufficient)
                    volume = {}
                    # Extract id
                    id_match = obj_str.find('"id"')
                    if id_match != -1:
                        id_start = obj_str.find('"', id_match + 3)
                        id_end = obj_str.find('"', id_start + 1)
                        if id_start != -1 and id_end != -1:
                            volume["id"] = obj_str[id_start+1:id_end]
                    # Extract name
                    name_match = obj_str.find('"name"')
                    if name_match != -1:
                        ns = obj_str.find('"', name_match + 5)
                        ne = obj_str.find('"', ns + 1)
                        if ns != -1 and ne != -1:
                            volume["name"] = obj_str[ns+1:ne]
                    # Extract project
                    proj_match = obj_str.find('"project"')
                    if proj_match != -1:
                        ps = obj_str.find('"', proj_match + 8)
                        pe = obj_str.find('"', ps + 1)
                        if ps != -1 and pe != -1:
                            volume["project"] = obj_str[ps+1:pe]
                    # Extract size (number)
                    size_match = obj_str.find('"size"')
                    if size_match != -1:
                        z = obj_str.find(':', size_match)
                        if z != -1:
                            z += 1
                            num_str = ""
                            while z < len(obj_str) and obj_str[z].isdigit():
                                num_str += obj_str[z]
                                z += 1
                            if num_str != "":
                                volume["size"] = int(num_str)
                    # Extract volume_type
                    vtype_match = obj_str.find('"volume_type"')
                    if vtype_match != -1:
                        vs = obj_str.find('"', vtype_match + 12)
                        ve = obj_str.find('"', vs + 1)
                        if vs != -1 and ve != -1:
                            volume["volume_type"] = obj_str[vs+1:ve]
                    if volume.get("id") != None:
                        volumes.append(volume)
                    break
        idx = obj_start + 1

    # Find volume by name and project
    volume_by_name = None
    for vol in volumes:
        if vol.get("name") == name and vol.get("project") == project:
            volume_by_name = vol
            break

    if state == "present":
        if volume_by_name != None:
            return {"changed": False, "msg": "Volume already exists", "data": {"volume": volume_by_name}}
        # Create new volume
        if size == None:
            fail("size is required when state is present")
        if volume_type == None:
            fail("volume_type is required when state is present")

        payload = {
            "name": name,
            "project": project,
            "size": size,
            "volume_type": volume_type
        }
        if ctx.check_mode:
            return {"changed": True, "msg": "would create volume " + name}

        create_res = api_call("POST", "/volumes", payload, ok_codes=[201])
        if create_res.get("skipped"):
            fail("API call skipped (check_mode)")

        if create_res["code"] != 201:
            fail("Failed to create volume: HTTP " + str(create_res["code"]) + ", " + create_res["body"])

        body = create_res["body"]
        vol_obj = {}
        # Minimal parsing of single object response (same technique)
        for key in ["id", "name", "project", "size", "volume_type"]:
            kq = '"' + key + '"'
            idx = body.find(kq)
            if idx != -1:
                # Find value
                colon = body.find(':', idx + len(kq))
                if colon != -1:
                    # Skip whitespace
                    j = colon + 1
                    while j < len(body) and body[j] in " \t\r\n":
                        j += 1
                    if body[j] == '"':
                        # String value
                        start = j + 1
                        end = start
                        while end < len(body) and body[end] != '"':
                            if body[end] == '\\' and end + 1 < len(body):
                                end += 2
                            else:
                                end += 1
                        value = body[start:end]
                    else:
                        # Number or null
                        num_start = j
                        while j < len(body) and (body[j].isdigit() or body[j] == '-'):
                            j += 1
                        if body[num_start:j].isdigit() or (body[num_start:j].startswith('-') and body[num_start+1:j].isdigit()):
                            value = int(body[num_start:j])
                        else:
                            value = None
                    vol_obj[key] = value
        return {"changed": True, "msg": "Volume created", "data": {"volume": vol_obj}}

    elif state == "absent":
        if volume_by_name == None:
            return {"changed": False, "msg": "Volume does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete volume " + name}
        delete_res = api_call("DELETE", "/volumes/" + volume_by_name["id"], ok_codes=[204])
        if delete_res.get("skipped"):
            fail("API call skipped (check_mode)")
        if delete_res["code"] != 204:
            fail("Failed to delete volume: HTTP " + str(delete_res["code"]) + ", " + delete_res["body"])
        return {"changed": True, "msg": "Volume deleted", "data": {}}
