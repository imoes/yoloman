def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    host = params.get("host", "localhost")
    port = params.get("port", 8500)
    scheme = params.get("scheme", "http")
    token = params.get("token")
    description = params.get("description")
    rules = params.get("rules")
    valid_datacenters = params.get("valid_datacenters", [])
    validate_certs = params.get("validate_certs", True)
    ca_path = params.get("ca_path")

    # Build base URL
    base_url = "%s://%s:%d" % (scheme, host, port)

    # Build curl args for GET request
    curl_args = [
        "curl", "-s", "-S", "-f", "-X", "GET",
        base_url + "/v1/acl/policy/name/" + name,
    ]
    if not validate_certs:
        curl_args.append("-k")
    if ca_path:
        curl_args.extend(["--cacert", ca_path])
    if token:
        curl_args.extend(["-H", "X-Consul-Token: " + token])

    # Check existence
    res_get = ctx.run(curl_args)
    if res_get.rc == 0:
        existing_policy = res_get.stdout.strip()
        policy_dict = parse_json(ctx, existing_policy)
        existing = {
            "id": policy_dict.get("ID", ""),
            "name": policy_dict.get("Name", ""),
            "description": policy_dict.get("Description", ""),
            "rules": policy_dict.get("Rules", ""),
            "valid_datacenters": policy_dict.get("Datacenters", []),
        }
    elif res_get.rc == 22 and "not found" in res_get.stderr.lower():
        existing = None
    else:
        fail("failed to retrieve policy: " + res_get.stderr)

    if state == "absent":
        if existing == None:
            return {"changed": False, "msg": "policy does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete policy " + name}
        delete_args = [
            "curl", "-s", "-S", "-f", "-X", "DELETE",
            base_url + "/v1/acl/policy/" + existing["id"],
        ]
        if not validate_certs:
            delete_args.append("-k")
        if ca_path:
            delete_args.extend(["--cacert", ca_path])
        if token:
            delete_args.extend(["-H", "X-Consul-Token: " + token])
        res_del = ctx.run(delete_args, mutates=True)
        if res_del.skipped:
            return {"changed": True, "msg": "would delete policy " + name}
        if res_del.rc != 0:
            fail("failed to delete policy: " + res_del.stderr)
        return {"changed": True, "msg": "deleted policy " + name, "data": {"policy": existing}}

    # Present: create or update
    desired = {
        "name": name,
        "description": description if description != None else "",
        "rules": rules if rules != None else "",
        "valid_datacenters": [] if valid_datacenters == None else list(valid_datacenters),
    }

    if existing != None:
        need_update = (
            existing["description"] != desired["description"] or
            existing["rules"] != desired["rules"] or
            sorted(existing["valid_datacenters"]) != sorted(desired["valid_datacenters"])
        )
        if not need_update:
            return {"changed": False, "msg": "policy " + name + " already exists", "data": {"policy": existing}}

        if ctx.check_mode:
            return {"changed": True, "msg": "would update policy " + name}
        payload = {
            "ID": existing["id"],
            "Name": name,
            "Description": desired["description"],
            "Rules": desired["rules"],
            "Datacenters": desired["valid_datacenters"],
        }
        body = json_encode(payload)
        update_args = [
            "curl", "-s", "-S", "-f", "-X", "PUT",
            "-H", "Content-Type: application/json",
        ]
        if not validate_certs:
            update_args.append("-k")
        if ca_path:
            update_args.extend(["--cacert", ca_path])
        if token:
            update_args.extend(["-H", "X-Consul-Token: " + token])
        update_args.extend(["-d", body, base_url + "/v1/acl/policy/" + existing["id"]])
        res_upd = ctx.run(update_args, mutates=True)
        if res_upd.skipped:
            return {"changed": True, "msg": "would update policy " + name}
        if res_upd.rc != 0:
            fail("failed to update policy: " + res_upd.stderr)
        policy_dict = parse_json(ctx, res_upd.stdout)
        updated_policy = {
            "id": policy_dict.get("ID", ""),
            "name": policy_dict.get("Name", ""),
            "description": policy_dict.get("Description", ""),
            "rules": policy_dict.get("Rules", ""),
            "valid_datacenters": policy_dict.get("Datacenters", []),
        }
        return {"changed": True, "msg": "updated policy " + name, "data": {"policy": updated_policy, "operation": "update"}}

    # Create new
    payload = {
        "Name": name,
        "Description": desired["description"],
        "Rules": desired["rules"],
        "Datacenters": desired["valid_datacenters"],
    }
    body = json_encode(payload)
    if ctx.check_mode:
        return {"changed": True, "msg": "would create policy " + name}
    create_args = [
        "curl", "-s", "-S", "-f", "-X", "POST",
        "-H", "Content-Type: application/json",
    ]
    if not validate_certs:
        create_args.append("-k")
    if ca_path:
        create_args.extend(["--cacert", ca_path])
    if token:
        create_args.extend(["-H", "X-Consul-Token: " + token])
    create_args.extend(["-d", body, base_url + "/v1/acl/policy"])
    res_crt = ctx.run(create_args, mutates=True)
    if res_crt.skipped:
        return {"changed": True, "msg": "would create policy " + name}
    if res_crt.rc != 0:
        fail("failed to create policy: " + res_crt.stderr)
    policy_dict = parse_json(ctx, res_crt.stdout)
    created_policy = {
        "id": policy_dict.get("ID", ""),
        "name": policy_dict.get("Name", ""),
        "description": policy_dict.get("Description", ""),
        "rules": policy_dict.get("Rules", ""),
        "valid_datacenters": policy_dict.get("Datacenters", []),
    }
    return {"changed": True, "msg": "created policy " + name, "data": {"policy": created_policy, "operation": "create"}}


def parse_json(ctx, text):
    d = {}
    text = text.strip()
    m = extract_string(text, '"ID"')
    if m:
        d["ID"] = m
    m = extract_string(text, '"Name"')
    if m:
        d["Name"] = m
    m = extract_string(text, '"Description"')
    if m:
        d["Description"] = m
    m = extract_string(text, '"Rules"')
    if m:
        d["Rules"] = m
    m = extract_array_of_strings(text, '"Datacenters"')
    if m != None:
        d["Datacenters"] = m
    return d


def extract_string(text, key):
    idx = text.find(key)
    if idx == -1:
        return None
    start = text.find('"', idx + len(key))
    if start == -1:
        return None
    start += 1
    end = start
    while end < len(text):
        if text[end] == '"':
            return text[start:end]
        end += 1
    return None


def extract_array_of_strings(text, key):
    idx = text.find(key)
    if idx == -1:
        return []
    start = text.find('[', idx + len(key))
    if start == -1:
        return []
    end = start
    depth = 1
    inside_string = False
    while end < len(text) and depth > 0:
        c = text[end]
        if not inside_string:
            if c == '[':
                depth += 1
            elif c == ']':
                depth -= 1
                if depth == 0:
                    break
            elif c == '"':
                inside_string = True
        else:
            if c == '\\' and end + 1 < len(text):
                end += 1
            elif c == '"':
                inside_string = False
        end += 1
    if depth != 0:
        return []
    arr_str = text[start+1:end].strip()
    if not arr_str:
        return []
    items = []
    parts = arr_str.split('", "')
    for part in parts:
        part = part.strip().strip('"')
        if part:
            items.append(part)
    return items


def json_encode(d):
    parts = []
    for k, v in d.items():
        if isinstance(v, bool):
            val = "true" if v else "false"
        elif isinstance(v, int):
            val = str(v)
        elif isinstance(v, list):
            val = "["
            for idx, s in enumerate(v):
                if idx > 0:
                    val += ", "
                val += '"' + escape_json_string(s) + '"'
            val += "]"
        else:
            val = '"' + escape_json_string(v) + '"'
        parts.append('"' + k + '": ' + val)
    return "{" + ", ".join(parts) + "}"


def escape_json_string(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')
