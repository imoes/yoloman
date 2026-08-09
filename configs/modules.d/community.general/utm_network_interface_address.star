def main(ctx, params):
    name = params["name"]
    address = params["address"]
    address6 = params.get("address6")
    comment = params.get("comment", "")
    resolved = params.get("resolved")
    resolved6 = params.get("resolved6")
    state = params.get("state", "present")
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)
    headers = params.get("headers", {})

    base_url = utm_protocol + "://" + utm_host + ":" + str(utm_port)
    endpoint = "/network/interface_address"
    full_url = base_url + endpoint
    auth_header = "X-Auth-Token: " + utm_token

    req_headers = ["-H", auth_header]
    for k, v in headers.items():
        req_headers.extend(["-H", str(k) + ": " + str(v)])

    if validate_certs:
        curl_opts = ["curl", "-s", "-k"] + req_headers
    else:
        curl_opts = ["curl", "-s"] + req_headers

    # Probe: check if object exists by name
    probe_cmd = curl_opts + [
        "-X", "GET", full_url + "?name=" + name
    ]
    res = ctx.run(probe_cmd)
    if res.rc != 0:
        fail("failed to probe existing object: " + res.stderr)

    # Parse response JSON manually (basic)
    content = res.stdout.strip()
    objects = []
    if content != "":
        idx = content.find('"objects"')
        if idx != -1:
            start = content.find("[", idx)
            if start != -1:
                depth = 0
                end = start
                for i in range(start, len(content)):
                    if content[i] == "[":
                        depth += 1
                    elif content[i] == "]":
                        depth -= 1
                        if depth == 0:
                            end = i + 1
                            break
                raw_arr = content[start:end]
                objects = _parse_json_array(raw_arr)

    existing = None
    for obj in objects:
        if obj.get("name") == name:
            existing = obj
            break

    if state == "absent":
        if existing == None:
            return {"changed": False, "msg": "object not found, nothing to do"}
        ref = existing.get("_ref")
        if ref == None:
            fail("cannot delete: missing _ref")
        del_url = full_url + "/" + ref
        del_cmd = curl_opts + ["-X", "DELETE", del_url]
        del_res = ctx.run(del_cmd, mutates=True)
        if del_res.skipped:
            return {"changed": True, "msg": "would delete " + name}
        if del_res.rc != 0:
            fail("failed to delete " + name + ": " + del_res.stderr)
        return {"changed": True, "msg": "deleted " + name}

    # state == present
    if existing != None:
        ref = existing.get("_ref")
        if ref == None:
            fail("cannot update: missing _ref")

        data = {
            "name": name,
            "address": address,
            "comment": comment
        }
        if address6 != None:
            data["address6"] = address6
        if resolved != None:
            data["resolved"] = resolved
        if resolved6 != None:
            data["resolved6"] = resolved6

        update_cmd = curl_opts + [
            "-X", "PUT",
            "-d", _dict_to_json(data),
            full_url + "/" + ref
        ]
        update_res = ctx.run(update_cmd, mutates=True)
        if update_res.skipped:
            return {"changed": True, "msg": "would update " + name}
        if update_res.rc != 0:
            fail("failed to update " + name + ": " + update_res.stderr)
        return {"changed": True, "msg": "updated " + name}

    # Create new
    data = {
        "name": name,
        "address": address,
        "comment": comment
    }
    if address6 != None:
        data["address6"] = address6
    if resolved != None:
        data["resolved"] = resolved
    if resolved6 != None:
        data["resolved6"] = resolved6

    create_cmd = curl_opts + [
        "-X", "POST",
        "-d", _dict_to_json(data),
        full_url
    ]
    create_res = ctx.run(create_cmd, mutates=True)
    if create_res.skipped:
        return {"changed": True, "msg": "would create " + name}
    if create_res.rc != 0:
        fail("failed to create " + name + ": " + create_res.stderr)
    return {"changed": True, "msg": "created " + name}


def _dict_to_json(d):
    items = []
    for k in sorted(d.keys()):
        v = d[k]
        if type(v) == "bool":
            val = "true" if v else "false"
        elif type(v) == "int":
            val = str(v)
        elif type(v) == "string":
            val = "\"" + _escape_string(v) + "\""
        else:
            val = "\"" + _escape_string(str(v)) + "\""
        items.append("\"" + _escape_string(str(k)) + "\": " + val)
    return "{" + ", ".join(items) + "}"


def _escape_string(s):
    return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")


def _parse_json_array(s):
    if not s.startswith("[") or not s.endswith("]"):
        fail("invalid json array: " + s)
    inner = s[1:-1].strip()
    if len(inner) == 0:
        return []
    objects = []
    depth = 0
    current = []
    in_string = False
    i = 0
    while i < len(inner):
        c = inner[i]
        if c == '"' and (i == 0 or inner[i-1] != '\\'):
            in_string = not in_string
            current.append(c)
        elif in_string:
            current.append(c)
        elif c == '{':
            depth += 1
            current.append(c)
        elif c == '}':
            depth -= 1
            current.append(c)
            if depth == 0 and i + 1 < len(inner) and inner[i+1:i+3] == ", ":
                objects.append("".join(current))
                current = []
                i += 2
                continue
        elif c == ',' and depth == 0:
            pass
        else:
            current.append(c)
        i += 1
    if len(current) > 0:
        objects.append("".join(current))

    result = []
    for obj_str in objects:
        obj_str = obj_str.strip()
        if obj_str == "":
            continue
        obj = {}
        body = obj_str[1:-1].strip()
        j = 0
        while j < len(body):
            if body[j] == '"':
                key_start = j + 1
                while j < len(body) and body[j] != '"':
                    j += 1
                key = body[key_start:j]
                j += 1
                while j < len(body) and (body[j] == ' ' or body[j] == '\t'):
                    j += 1
                if j < len(body) and body[j] == ':':
                    j += 1
                while j < len(body) and (body[j] == ' ' or body[j] == '\t'):
                    j += 1
                if j < len(body) and body[j] == '"':
                    val_start = j + 1
                    j += 1
                    while j < len(body) and not (body[j] == '"' and (j == 0 or body[j-1] != '\\')):
                        j += 1
                    val = body[val_start:j]
                    obj[key] = val
                    j += 1
                elif j < len(body) and body[j] == 't':
                    obj[key] = True
                    j += 4
                elif j < len(body) and body[j] == 'f':
                    obj[key] = False
                    j += 5
                elif j < len(body) and (body[j].isdigit() or body[j] == '-'):
                    val_end = j
                    if body[j] == '-':
                        val_end += 1
                    while val_end < len(body) and body[val_end].isdigit():
                        val_end += 1
                    obj[key] = int(body[j:val_end])
                    j = val_end
                else:
                    obj[key] = ""
            else:
                j += 1
        result.append(obj)
    return result
