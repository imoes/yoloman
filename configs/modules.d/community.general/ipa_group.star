def main(ctx, params):
    cn = params["cn"]
    state = params.get("state", "present")
    append = params.get("append", False)
    description = params.get("description")
    external = params.get("external")
    external_user = params.get("external_user")
    gidnumber = params.get("gidnumber")
    group_list = params.get("group")
    nonposix = params.get("nonposix")
    user_list = params.get("user")
    validate_certs = params.get("validate_certs", True)

    ipa_host = params.get("ipa_host", "ipa.example.com")
    ipa_port = params.get("ipa_port", 443)
    ipa_prot = params.get("ipa_prot", "https")
    ipa_user = params.get("ipa_user", "admin")
    ipa_pass = params.get("ipa_pass")
    ipa_timeout = params.get("ipa_timeout", 10)

    base_url = ipa_prot + "://" + ipa_host
    if ipa_port != 80 and ipa_port != 443:
        base_url = base_url + ":" + str(ipa_port)

    if external_user != None and external != True:
        fail("external_user can only be set if external = True")

    # Build JSON payload manually
    def to_json(obj):
        if type(obj) == type(True):
            return "true" if obj else "false"
        elif type(obj) == type({}):
            items = []
            for k in sorted(obj.keys()):
                items.append('"' + k + '": ' + to_json(obj[k]))
            return "{" + ", ".join(items) + "}"
        elif type(obj) == type([]):
            items = []
            for x in obj:
                items.append(to_json(x))
            return "[" + ", ".join(items) + "]"
        elif type(obj) == type(""):
            # Escape quotes and backslashes
            escaped = ""
            for c in obj:
                if c == '"':
                    escaped = escaped + "\\\""
                elif c == '\\':
                    escaped = escaped + "\\\\"
                elif c == '\n':
                    escaped = escaped + "\\n"
                else:
                    escaped = escaped + c
            return '"' + escaped + '"'
        elif obj == None:
            return "null"
        elif type(obj) == type(0):
            return str(obj)
        else:
            fail("Unsupported type in JSON: " + str(type(obj)))

    def ipa_request(method, name, item=None):
        url = base_url + "/ipa/json"
        payload = {
            "method": method,
            "params": [[name], item] if item != None else [[name]],
            "id": 0
        }
        payload_str = to_json(payload)
        auth_args = []
        if ipa_pass != None:
            auth_args = ["-u", ipa_user + ":" + ipa_pass]
        curl_cmd = ["curl", "-s", "-k" if not validate_certs else "-k", "-X", "POST",
                    "-H", "Content-Type: application/json",
                    "-H", "Accept: application/json"] + auth_args + ["-d", payload_str, url]
        res = ctx.run(curl_cmd, mutates=True, ok_codes=[0])
        if res.rc != 0:
            fail("IPA request failed: " + res.stderr)
        # Extract JSON result using simple parsing
        stdout = res.stdout
        start_idx = stdout.find('"result":')
        if start_idx == -1:
            fail("IPA response missing 'result' field")
        start_idx = stdout.find('{', start_idx)
        if start_idx == -1:
            fail("IPA response missing 'result' object")
        depth = 1
        end_idx = start_idx
        for i in range(start_idx + 1, len(stdout)):
            c = stdout[i]
            if c == '{':
                depth = depth + 1
            elif c == '}':
                depth = depth - 1
                if depth == 0:
                    end_idx = i + 1
                    break
        if end_idx <= start_idx:
            fail("IPA response 'result' field parsing failed")
        result_str = stdout[start_idx:end_idx]
        # Parse result_str into dict
        return _parse_simple_json_object(result_str)

    def _parse_simple_json_object(s):
        result = {}
        s = s.strip()
        if s == "{}":
            return result
        # Remove braces
        if s.startswith("{") and s.endswith("}"):
            s = s[1:-1]
        else:
            fail("Invalid JSON object: " + s)
        # Split by top-level commas (simple case)
        parts = []
        depth = 0
        current = ""
        for c in s:
            if c == '{' or c == '[':
                depth = depth + 1
                current = current + c
            elif c == '}' or c == ']':
                depth = depth - 1
                current = current + c
            elif c == ',' and depth == 0:
                parts.append(current.strip())
                current = ""
            else:
                current = current + c
        if current.strip() != "":
            parts.append(current.strip())
        for part in parts:
            if part == "":
                continue
            # Split key and value
            colon_idx = part.find(':')
            if colon_idx == -1:
                continue
            key = part[:colon_idx].strip()
            value = part[colon_idx + 1:].strip()
            # Remove quotes from key
            if key.startswith('"') and key.endswith('"'):
                key = key[1:-1]
            result[key] = _parse_simple_json_value(value)
        return result

    def _parse_simple_json_value(s):
        s = s.strip()
        if s == "null":
            return None
        elif s == "true":
            return True
        elif s == "false":
            return False
        elif s.startswith('"') and s.endswith('"'):
            return s[1:-1]
        elif s.startswith('['):
            if s == "[]":
                return []
            s_inner = s[1:-1].strip()
            if s_inner == "":
                return []
            # Split by top-level commas
            parts = []
            depth = 0
            current = ""
            for c in s_inner:
                if c == '[' or c == '{':
                    depth = depth + 1
                    current = current + c
                elif c == ']' or c == '}':
                    depth = depth - 1
                    current = current + c
                elif c == ',' and depth == 0:
                    parts.append(current.strip())
                    current = ""
                else:
                    current = current + c
            if current.strip() != "":
                parts.append(current.strip())
            result = []
            for p in parts:
                result.append(_parse_simple_json_value(p))
            return result
        elif s.startswith('{'):
            return _parse_simple_json_object(s)
        else:
            # Try number
            if s.isdigit() or (s.startswith('-') and s[1:].isdigit()):
                return int(s)
            return s

    def modify_if_diff(name, ipa_list, module_list, add_fn, remove_fn, append):
        changed = False
        if not append:
            # Remove all in ipa_list not in module_list
            for item in ipa_list:
                if item not in module_list:
                    # Remove item
                    if type(item) == type(""):
                        if not ctx.check_mode:
                            remove_fn(name, [item])
                        changed = True
        # Add all in module_list not in ipa_list
        for item in module_list:
            if item not in ipa_list:
                if type(item) == type(""):
                    if not ctx.check_mode:
                        add_fn(name, [item])
                    changed = True
        return changed

    # Check if group exists
    ipa_group = ipa_request("group_find", cn, {"all": True, "cn": cn})
    group_exists = ipa_group != None and ipa_group != {}

    if state == "present":
        if not group_exists:
            # Create group
            module_group = {}
            if description != None:
                module_group["description"] = description
            if external != None:
                module_group["external"] = external
            if gidnumber != None:
                module_group["gidnumber"] = gidnumber
            if nonposix != None:
                module_group["nonposix"] = nonposix
            if not ctx.check_mode:
                ipa_request("group_add", cn, [module_group])
            return {"changed": True, "msg": "group created"}
        else:
            # Modify group if needed
            module_group = {}
            if description != None:
                module_group["description"] = description
            if external != None:
                module_group["external"] = external
            if gidnumber != None:
                module_group["gidnumber"] = gidnumber
            if nonposix != None:
                if not nonposix and ipa_group.get("nonposix"):
                    module_group["posix"] = True
                elif nonposix and not ipa_group.get("nonposix"):
                    fail("cannot change posix group to nonposix")
            diff = {}
            for k, v in module_group.items():
                if v != ipa_group.get(k):
                    diff[k] = v
            if len(diff) > 0:
                if not ctx.check_mode:
                    ipa_request("group_mod", cn, [diff])
                return {"changed": True, "msg": "group modified"}
            # Handle groups
            changed = False
            if group_list != None:
                ipa_groups = ipa_group.get("member_group", [])
                if type(ipa_groups) != type([]):
                    ipa_groups = []
                if modify_if_diff(cn, ipa_groups, group_list, 
                                  lambda n, items: ipa_request("group_add_member_group", n, items),
                                  lambda n, items: ipa_request("group_remove_member_group", n, items), append):
                    changed = True
            # Handle users
            if user_list != None:
                ipa_users = ipa_group.get("member_user", [])
                if type(ipa_users) != type([]):
                    ipa_users = []
                if modify_if_diff(cn, ipa_users, user_list,
                                  lambda n, items: ipa_request("group_add_member_user", n, items),
                                  lambda n, items: ipa_request("group_remove_member_user", n, items), append):
                    changed = True
            # Handle external users
            if external_user != None:
                ipa_external = ipa_group.get("ipaexternalmember", [])
                if type(ipa_external) != type([]):
                    ipa_external = []
                if modify_if_diff(cn, ipa_external, external_user,
                                  lambda n, items: ipa_request("group_add_member_externaluser", n, items),
                                  lambda n, items: ipa_request("group_remove_member_externaluser", n, items), append):
                    changed = True
            if changed:
                return {"changed": True, "msg": "group updated"}
            else:
                return {"changed": False, "msg": "group already exists"}
    else:
        # Absent
        if group_exists:
            if not ctx.check_mode:
                ipa_request("group_del", cn, [])
            return {"changed": True, "msg": "group deleted"}
        else:
            return {"changed": False, "msg": "group not present"}
