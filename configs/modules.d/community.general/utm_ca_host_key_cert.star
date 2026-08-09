def main(ctx, params):
    name = params["name"]
    ca = params["ca"]
    meta = params["meta"]
    certificate = params["certificate"]
    comment = params.get("comment", "")
    encrypted = params.get("encrypted", False)
    key = params.get("key", "")
    state = params.get("state", "present")
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)

    # Build base URL
    base_url = utm_protocol + "://" + utm_host + ":" + str(utm_port) + "/api/"

    # Prepare headers
    headers = {
        "X-Token": utm_token,
        "Content-Type": "application/json"
    }
    extra_headers = params.get("headers", {})
    for k, v in extra_headers.items():
        headers[k] = v

    # State-specific logic
    if state == "absent":
        # Check if entry exists
        res = ctx.run(
            ["curl", "-s", "-k", "-X", "GET", base_url + "ca/host_key_cert/" + name, "-H", "X-Token: " + utm_token],
            mutates=False
        )
        if res.rc == 0:
            # Exists: delete it
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete ca host_key_cert " + name}
            res_del = ctx.run(
                ["curl", "-s", "-k", "-X", "DELETE", base_url + "ca/host_key_cert/" + name, "-H", "X-Token: " + utm_token],
                mutates=True
            )
            if res_del.rc != 0:
                fail("failed to delete ca host_key_cert " + name + ": " + res_del.stderr)
            return {"changed": True, "msg": "deleted ca host_key_cert " + name}
        elif res.rc == 22:  # 404 (Not Found) via HTTP
            return {"changed": False, "msg": "ca host_key_cert " + name + " not found"}
        else:
            fail("failed to check ca host_key_cert " + name + ": " + res.stderr)

    elif state == "present":
        # Prepare payload
        payload = {
            "name": name,
            "ca": ca,
            "meta": meta,
            "certificate": certificate,
            "comment": comment,
            "encrypted": 1 if encrypted else 0,
            "key": key
        }

        # Check if entry exists
        res = ctx.run(
            ["curl", "-s", "-k", "-X", "GET", base_url + "ca/host_key_cert/" + name, "-H", "X-Token: " + utm_token],
            mutates=False
        )

        if res.rc == 0:
            # Entry exists: update if needed
            # Parse JSON manually using simple extraction since no json module
            stdout = res.stdout.strip()
            current = parse_json_object(stdout)

            # Determine if update is needed
            needs_update = False
            for key_name in ["ca", "certificate", "comment", "encrypted", "key", "meta"]:
                current_val = current.get(key_name)
                new_val = payload.get(key_name)
                # Handle encrypted: backend uses int, payload uses bool
                if key_name == "encrypted":
                    current_val = current_val == 1
                if current_val != new_val:
                    needs_update = True
                    break

            if needs_update:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update ca host_key_cert " + name}
                # Convert payload back for API (encrypted as int)
                payload_for_api = dict(payload)
                payload_for_api["encrypted"] = 1 if payload["encrypted"] else 0
                payload_json = json_dumps(payload_for_api)
                res_put = ctx.run(
                    [
                        "curl", "-s", "-k", "-X", "PUT", base_url + "ca/host_key_cert/" + name,
                        "-H", "X-Token: " + utm_token,
                        "-H", "Content-Type: application/json",
                        "-d", payload_json
                    ],
                    mutates=True
                )
                if res_put.rc != 0:
                    fail("failed to update ca host_key_cert " + name + ": " + res_put.stderr)
                return {"changed": True, "msg": "updated ca host_key_cert " + name}
            else:
                return {"changed": False, "msg": "ca host_key_cert " + name + " already correct"}

        else:
            # Entry does not exist: create it
            if ctx.check_mode:
                return {"changed": True, "msg": "would create ca host_key_cert " + name}

            payload_for_api = dict(payload)
            payload_for_api["encrypted"] = 1 if payload["encrypted"] else 0
            payload_json = json_dumps(payload_for_api)
            res_post = ctx.run(
                [
                    "curl", "-s", "-k", "-X", "POST", base_url + "ca/host_key_cert",
                    "-H", "X-Token: " + utm_token,
                    "-H", "Content-Type: application/json",
                    "-d", payload_json
                ],
                mutates=True
            )
            if res_post.rc != 0:
                fail("failed to create ca host_key_cert " + name + ": " + res_post.stderr)
            return {"changed": True, "msg": "created ca host_key_cert " + name}

    else:
        fail("unsupported state: " + state)


def parse_json_object(s):
    obj = {}
    # Strip braces
    s = s.strip()
    if not s.startswith("{") or not s.endswith("}"):
        return obj
    s = s[1:-1]
    # Split key-value pairs by comma (simple approach, assumes no commas in values)
    parts = s.split(",")
    for part in parts:
        part = part.strip()
        if not part:
            continue
        colon_idx = part.find(":")
        if colon_idx == -1:
            continue
        key = part[:colon_idx].strip().strip("\"'")
        value = part[colon_idx + 1:].strip()
        # Unquote value
        if value.startswith("\"") and value.endswith("\""):
            value = value[1:-1]
        elif value == "true":
            value = True
        elif value == "false":
            value = False
        elif value == "null":
            value = None
        elif value.isdigit():
            value = int(value)
        obj[key] = value
    return obj


def json_dumps(obj):
    items = []
    for k in sorted(obj.keys()):
        v = obj.get(k)
        if type(v) == "bool":
            items.append("\"%s\": %s" % (k, "true" if v else "false"))
        elif v == None:
            items.append("\"%s\": null" % k)
        elif type(v) == "int" or type(v) == "float":
            items.append("\"%s\": %s" % (k, str(v)))
        else:
            # Escape quotes in string
            s = str(v).replace("\\", "\\\\").replace("\"", "\\\"")
            items.append("\"%s\": \"%s\"" % (k, s))
    return "{" + ", ".join(items) + "}"
