def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    op = params.get("op", "AND")
    path = params.get("path", [])
    skip_custom_threats_filters = params.get("skip_custom_threats_filters", [])
    skip_threats_filter_categories = params.get("skip_threats_filter_categories", [])
    skipav = params.get("skipav", False)
    skipbadclients = params.get("skipbadclients", False)
    skipcookie = params.get("skipcookie", False)
    skipform = params.get("skipform", False)
    skipform_missingtoken = params.get("skipform_missingtoken", False)
    skiphtmlrewrite = params.get("skiphtmlrewrite", False)
    skiptft = params.get("skiptft", False)
    skipurl = params.get("skipurl", False)
    source = params.get("source", [])
    status = params.get("status", True)
    headers = params.get("headers", {})
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)

    # Build base URL
    protocol = "http" if utm_protocol == "http" else "https"
    base_url = protocol + "://" + utm_host + ":" + str(utm_port) + "/api/"

    endpoint = "reverse_proxy/exception"
    url = base_url + endpoint

    # Build headers list for curl
    headers_list = []
    headers_list.append("-H")
    headers_list.append("accept: application/json")
    headers_list.append("-H")
    headers_list.append("content-type: application/json")
    headers_list.append("-H")
    headers_list.append("X-Auth-Token:" + utm_token)
    for k, v in headers.items():
        headers_list.append("-H")
        headers_list.append(str(k) + ": " + str(v))

    # Probe for existing object by name
    list_cmd = ["curl", "-s", "-X", "GET", url]
    list_cmd.extend(headers_list)
    list_res = ctx.run(list_cmd, mutates=False)
    if list_res.rc != 0:
        fail("failed to list exceptions: " + list_res.stderr)

    # Simple parsing: look for name in stdout
    lines = list_res.stdout.strip().split("\n") if list_res.stdout.strip() != "" else []
    obj_ref = None
    existing = None
    for line in lines:
        if line == "":
            continue
        if '"name": "' + name + '"' in line:
            obj_ref = line
            existing = line
            break

    # If not found by line scan, try explicit name search
    if existing == None:
        search_url = url + "?name=" + name
        search_cmd = ["curl", "-s", "-X", "GET", search_url]
        search_cmd.extend(headers_list)
        search_res = ctx.run(search_cmd, mutates=False)
        if search_res.rc == 0 and search_res.stdout.strip() != "":
            if '"name": "' + name + '"' in search_res.stdout:
                obj_ref = search_res.stdout.strip()
                existing = search_res.stdout.strip()

    # Build payload dict
    desired_payload = {
        "name": name,
        "op": op,
        "path": path,
        "skip_custom_threats_filters": skip_custom_threats_filters,
        "skip_threats_filter_categories": skip_threats_filter_categories,
        "skipav": skipav,
        "skipbadclients": skipbadclients,
        "skipcookie": skipcookie,
        "skipform": skipform,
        "skipform_missingtoken": skipform_missingtoken,
        "skiphtmlrewrite": skiphtmlrewrite,
        "skiptft": skiptft,
        "skipurl": skipurl,
        "source": source,
        "status": status
    }

    # Convert to simple JSON-like string (single-line, double quotes)
    def to_json_string(payload):
        parts = []
        for k, v in payload.items():
            if type(v) == "bool":
                v_str = "true" if v else "false"
            elif type(v) == "int":
                v_str = str(v)
            elif type(v) == "string":
                v_str = "\"" + v.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
            elif type(v) == "list":
                items = []
                for item in v:
                    if type(item) == "bool":
                        items.append("true" if item else "false")
                    elif type(item) == "string":
                        items.append("\"" + item.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")
                    else:
                        items.append(str(item))
                v_str = "[" + ",".join(items) + "]"
            else:
                v_str = "\"" + str(v).replace("\\", "\\\\").replace("\"", "\\\"") + "\""
            parts.append("\"" + k + "\":" + v_str)
        return "{" + ",".join(parts) + "}"

    payload_json = to_json_string(desired_payload)

    if state == "absent":
        if existing != None:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete proxy exception " + name}
            delete_url = url + "/" + name
            delete_cmd = ["curl", "-s", "-X", "DELETE", delete_url]
            delete_cmd.extend(headers_list)
            del_res = ctx.run(delete_cmd, mutates=True)
            if del_res.rc != 0:
                fail("failed to delete proxy exception " + name + ": " + del_res.stderr)
            return {"changed": True, "msg": "deleted proxy exception " + name}
        else:
            return {"changed": False, "msg": "proxy exception " + name + " not found"}

    # state == "present"
    # For idempotency, compare only keys present in desired_payload
    # Since parsing full JSON is hard without stdlib, use simple name match and skip full diff
    if existing != None:
        return {"changed": False, "msg": "proxy exception " + name + " already present"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would create proxy exception " + name}

    create_cmd = ["curl", "-s", "-X", "POST", url]
    create_cmd.extend(headers_list)
    create_cmd.extend(["-d", payload_json])
    create_res = ctx.run(create_cmd, mutates=True)
    if create_res.rc != 0:
        fail("failed to create proxy exception " + name + ": " + create_res.stderr)

    return {"changed": True, "msg": "created proxy exception " + name}
