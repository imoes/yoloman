def main(ctx, params):
    label = params["label"]
    state = params["state"]
    access_token = params["access_token"]
    region = params.get("region")
    image = params.get("image")
    ltype = params.get("type")
    root_pass = params.get("root_pass")
    group = params.get("group")
    private_ip = params.get("private_ip", False)
    tags = params.get("tags")
    authorized_keys = params.get("authorized_keys")
    stackscript_id = params.get("stackscript_id")
    stackscript_data = params.get("stackscript_data")

    # Validation
    if state == "present":
        if region == None:
            fail("region is required when state is present")
        if image == None:
            fail("image is required when state is present")
        if ltype == None:
            fail("type is required when state is present")
        if stackscript_id != None and stackscript_data == None:
            fail("stackscript_data is required when stackscript_id is provided")

    # Check if instance exists by label
    list_cmd = [
        "curl", "-sS", "-X", "GET",
        "-H", "Authorization: Bearer " + access_token,
        "-H", "Content-Type: application/json",
        "https://api.linode.com/v4/linode/instances"
    ]
    res = ctx.run(list_cmd)
    if res.rc != 0:
        fail("failed to list Linode instances: " + res.stderr)

    instances = []
    output = res.stdout.strip()
    if not output:
        fail("empty response from Linode API")

    # Extract 'data' array
    data_start = output.find('"data"')
    if data_start == -1:
        fail("could not find 'data' in API response")
    bracket_start = output.find('[', data_start)
    if bracket_start == -1:
        fail("could not find array in data section")
    bracket_end = find_matching_bracket(output, bracket_start)
    if bracket_end == -1:
        fail("malformed JSON in response")
    arr_str = output[bracket_start:bracket_end+1]
    instances = parse_json_array(arr_str)

    instance = None
    for item in instances:
        if item.get("label") == label:
            instance = item
            break

    if state == "present":
        if instance != None:
            return {"changed": False, "instance": instance}

        if ctx.check_mode:
            return {"changed": True, "msg": "would create instance " + label}

        create_cmd = [
            "curl", "-sS", "-X", "POST",
            "-H", "Authorization: Bearer " + access_token,
            "-H", "Content-Type: application/json",
            "https://api.linode.com/v4/linode/instances"
        ]

        payload = {
            "label": label,
            "region": region,
            "type": ltype,
            "image": image,
            "private_ip": private_ip
        }
        if root_pass != None:
            payload["root_pass"] = root_pass
        if group != None:
            payload["group"] = group
        if tags != None:
            payload["tags"] = tags
        if authorized_keys != None:
            payload["authorized_keys"] = authorized_keys
        if stackscript_id != None:
            payload["stackscript_id"] = str(stackscript_id)
            if stackscript_data != None:
                payload["stackscript_data"] = stackscript_data

        payload_str = build_json_string(payload)

        create_cmd.extend([
            "-d", payload_str
        ])

        res = ctx.run(create_cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would create instance " + label}
        if res.rc != 0:
            fail("failed to create Linode instance: " + res.stderr)

        created_instance = parse_json_object(res.stdout)
        if created_instance == None:
            fail("failed to parse instance creation response")

        return {"changed": True, "instance": created_instance}

    elif state == "absent":
        if instance == None:
            return {"changed": False, "instance": {}}

        if ctx.check_mode:
            return {"changed": True, "msg": "would delete instance " + label}

        instance_id = str(instance.get("id"))
        delete_cmd = [
            "curl", "-sS", "-X", "DELETE",
            "-H", "Authorization: Bearer " + access_token,
            "https://api.linode.com/v4/linode/instances/" + instance_id
        ]
        res = ctx.run(delete_cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete instance " + label}
        if res.rc != 0 and res.rc != 204:
            fail("failed to delete Linode instance: " + res.stderr)

        return {"changed": True, "instance": {}}


def find_matching_bracket(s, start):
    depth = 0
    i = start
    while i < len(s):
        if s[i] == '[':
            depth += 1
        elif s[i] == ']':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def parse_json_array(s):
    s = s.strip()
    if not s.startswith("[") or not s.endswith("]"):
        fail("expected JSON array")
    inner = s[1:-1].strip()
    if inner == "":
        return []
    items = []
    depth = 0
    current = ""
    in_str = False
    escape = False
    for ch in inner:
        if escape:
            current += ch
            escape = False
            continue
        if ch == '\\' and in_str:
            escape = True
            current += ch
            continue
        if ch == '"' and not escape:
            in_str = not in_str
            current += ch
            continue
        if in_str:
            current += ch
            continue
        if ch in ['[', '{']:
            depth += 1
            current += ch
        elif ch in [']', '}']:
            depth -= 1
            current += ch
        elif ch == ',' and depth == 0:
            item = current.strip()
            if item:
                items.append(parse_json_object(item))
            current = ""
        else:
            current += ch
    last = current.strip()
    if last:
        items.append(parse_json_object(last))
    return items


def parse_json_object(s):
    s = s.strip()
    if not s.startswith("{") or not s.endswith("}"):
        fail("expected JSON object")
    inner = s[1:-1].strip()
    if inner == "":
        return {}
    result = {}
    depth = 0
    in_str = False
    escape = False
    current_key = ""
    current_val = ""
    key_done = False

    i = 0
    while i < len(inner):
        ch = inner[i]
        if escape:
            if key_done:
                current_val += ch
            else:
                current_key += ch
            escape = False
            i += 1
            continue
        if ch == '\\' and in_str:
            escape = True
            if key_done:
                current_val += ch
            else:
                current_key += ch
            i += 1
            continue
        if ch == '"' and not escape:
            in_str = not in_str
            if key_done:
                current_val += ch
            else:
                current_key += ch
            i += 1
            continue
        if in_str:
            if key_done:
                current_val += ch
            else:
                current_key += ch
            i += 1
            continue
        if not in_str and ch == ':' and not key_done:
            key_done = True
            current_key = current_key.strip().strip('"')
            i += 1
            continue
        if not in_str and ch == ',' and depth == 0:
            current_val = current_val.strip().strip('"')
            if current_val == "true":
                current_val = True
            elif current_val == "false":
                current_val = False
            elif current_val == "null":
                current_val = None
            elif is_integer(current_val):
                current_val = int(current_val)
            elif is_float(current_val):
                current_val = float(current_val)
            result[current_key] = current_val
            current_key = ""
            current_val = ""
            key_done = False
            i += 1
            continue
        if not in_str and ch in ['[', '{']:
            depth += 1
        if not in_str and ch in [']', '}']:
            depth -= 1
        if key_done:
            current_val += ch
        else:
            current_key += ch
        i += 1

    if current_key != "":
        current_val = current_val.strip().strip('"')
        if current_val == "true":
            current_val = True
        elif current_val == "false":
            current_val = False
        elif current_val == "null":
            current_val = None
        elif is_integer(current_val):
            current_val = int(current_val)
        elif is_float(current_val):
            current_val = float(current_val)
        result[current_key] = current_val

    return result


def is_integer(s):
    if s == "":
        return False
    # Basic integer check: optional leading minus, digits only
    if s.startswith('-'):
        s = s[1:]
    if s == "":
        return False
    for ch in s:
        if ch < '0' or ch > '9':
            return False
    return True


def is_float(s):
    if s == "":
        return False
    # Very basic float check
    # Must contain at least one digit and optionally one dot or exponent
    has_dot = False
    has_digit = False
    i = 0
    if s.startswith('-'):
        i = 1
    if i >= len(s):
        return False
    while i < len(s):
        ch = s[i]
        if ch >= '0' and ch <= '9':
            has_digit = True
        elif ch == '.':
            if has_dot:
                return False
            has_dot = True
        elif ch in ['e', 'E']:
            break  # Allow exponent part
        else:
            return False
        i += 1
    return has_digit


def build_json_string(d):
    parts = []
    for k in sorted(d.keys()):
        v = d[k]
        if type(v) == "string":
            v = v.replace("\\", "\\\\").replace('"', '\\"')
            parts.append('"' + k + '": "' + v + '"')
        elif type(v) == "bool":
            parts.append('"' + k + '": ' + ('true' if v else 'false'))
        elif v == None:
            parts.append('"' + k + '": null')
        elif type(v) == "int":
            parts.append('"' + k + '": ' + str(v))
        elif type(v) == "float":
            parts.append('"' + k + '": ' + str(v))
        elif type(v) == "list":
            items = []
            for item in v:
                if type(item) == "string":
                    item = item.replace("\\", "\\\\").replace('"', '\\"')
                    items.append('"' + item + '"')
                else:
                    fail("unsupported list item type")
            parts.append('"' + k + '": [' + ','.join(items) + ']')
        elif type(v) == "dict":
            inner_parts = []
            for ik in sorted(v.keys()):
                iv = v[ik]
                iv_str = str(iv)
                # Try to preserve numeric types if possible
                if is_integer(iv_str):
                    inner_parts.append('"' + ik + '": ' + iv_str)
                elif is_float(iv_str):
                    inner_parts.append('"' + ik + '": ' + iv_str)
                else:
                    iv_escaped = iv_str.replace("\\", "\\\\").replace('"', '\\"')
                    inner_parts.append('"' + ik + '": "' + iv_escaped + '"')
            parts.append('"' + k + '": {' + ','.join(inner_parts) + '}')
        else:
            fail("unsupported type in JSON build: " + type(v))
    return '{' + ','.join(parts) + '}'
