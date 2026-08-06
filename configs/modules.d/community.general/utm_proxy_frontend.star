def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)

    # Build base URL
    base_url = "%s://%s:%d/api/%s" % (
        utm_protocol,
        utm_host,
        utm_port,
        "objects"
    )

    # Prepare headers string for curl
    token_header = "X-Token: " + utm_token
    content_header = "Content-Type: application/json"
    insecure_arg = [] if validate_certs else ["--insecure"]

    # Build request body dict
    body_dict = {
        "name": name,
        "port": int(params.get("port", 80)),
        "type": params.get("type", "http"),
        "status": bool(params.get("status", True)),
        "address": params.get("address", "REF_DefaultInternalAddress"),
        "allowed_networks": params.get("allowed_networks", ["REF_NetworkAny"]),
        "domain": params.get("domain", []),
        "certificate": params.get("certificate", ""),
        "profile": params.get("profile", ""),
        "lbmethod": params.get("lbmethod", "bybusyness"),
        "xheaders": bool(params.get("xheaders", False)),
        "preservehost": bool(params.get("preservehost", False)),
        "implicitredirect": bool(params.get("implicitredirect", False)),
        "htmlrewrite": bool(params.get("htmlrewrite", False)),
        "htmlrewrite_cookies": bool(params.get("htmlrewrite_cookies", False)),
        "disable_compression": bool(params.get("disable_compression", False)),
        "add_content_type_header": bool(params.get("add_content_type_header", False)),
        "comment": params.get("comment", ""),
        "locations": params.get("locations", []),
        "exceptions": params.get("exceptions", [])
    }

    # Convert body to JSON-like string manually (simple case)
    def to_json(d):
        items = []
        for k in sorted(d.keys()):
            v = d[k]
            if type(v) == "bool":
                val_str = "true" if v else "false"
            elif type(v) == "int":
                val_str = str(v)
            elif type(v) == "string":
                # Escape quotes and backslashes
                s = v.replace("\\", "\\\\").replace('"', '\\"')
                val_str = '"' + s + '"'
            elif type(v) == "list":
                elements = [to_json(e) if type(e) == "dict" else (
                    '"%s"' % e.replace("\\", "\\\\").replace('"', '\\"') if type(e) == "string" else str(e)
                ) if type(e) != "bool" else ("true" if e else "false") for e in v]
                val_str = "[" + ",".join(elements) + "]"
            elif type(v) == "dict":
                val_str = to_json(v)
            else:
                val_str = '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'
            items.append('"%s":%s' % (k, val_str))
        return "{" + ",".join(items) + "}"

    body_str = to_json(body_dict)

    # Check if object exists
    fetch_cmd = [
        "curl",
        "-s",
        "-X", "GET",
        "-H", content_header,
        "-H", token_header
    ] + insecure_arg + [base_url + "/reverse_proxy/frontend/?name=" + name]
    res = ctx.run(fetch_cmd)
    if res.rc != 0:
        fail("Failed to fetch existing proxy frontend: " + res.stderr)

    existing = None
    if len(res.stdout.strip()) > 0:
        lines = res.stdout.strip().splitlines()
        for line in lines:
            if len(line.strip()) == 0:
                continue
            if '"name"' in line and name in line:
                existing = line.strip()
                break

    if state == "absent":
        if existing != None:
            delete_cmd = [
                "curl",
                "-s",
                "-X", "DELETE",
                "-H", content_header,
                "-H", token_header
            ] + insecure_arg + [base_url + "/reverse_proxy/frontend/" + name]
            res = ctx.run(delete_cmd)
            if res.rc != 0:
                fail("Failed to delete proxy frontend: " + res.stderr)
            return {"changed": True, "msg": "Deleted proxy frontend " + name}
        else:
            return {"changed": False, "msg": "Proxy frontend " + name + " does not exist"}

    # Check mode handling
    if ctx.check_mode:
        if existing == None:
            return {"changed": True, "msg": "would create proxy frontend " + name}
        else:
            return {"changed": True, "msg": "would update proxy frontend " + name}

    # Create or update
    if existing == None:
        post_cmd = [
            "curl",
            "-s",
            "-X", "POST",
            "-H", content_header,
            "-H", token_header
        ] + insecure_arg + ["-d", body_str, base_url + "/reverse_proxy/frontend/"]
        res = ctx.run(post_cmd)
        if res.rc != 0:
            fail("Failed to create proxy frontend: " + res.stderr)
        return {"changed": True, "msg": "Created proxy frontend " + name}
    else:
        put_cmd = [
            "curl",
            "-s",
            "-X", "PUT",
            "-H", content_header,
            "-H", token_header
        ] + insecure_arg + ["-d", body_str, base_url + "/reverse_proxy/frontend/" + name]
        res = ctx.run(put_cmd)
        if res.rc != 0:
            fail("Failed to update proxy frontend: " + res.stderr)
        return {"changed": True, "msg": "Updated proxy frontend " + name}
