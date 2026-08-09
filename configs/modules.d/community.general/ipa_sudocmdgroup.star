def main(ctx, params):
    cn = params["cn"]
    description = params.get("description")
    state = params.get("state", "present")
    sudocmd = params.get("sudocmd")
    ipa_host = params.get("ipa_host", "ipa.example.com")
    ipa_pass = params.get("ipa_pass")
    ipa_port = params.get("ipa_port", 443)
    ipa_prot = params.get("ipa_prot", "https")
    ipa_timeout = params.get("ipa_timeout", 10)
    ipa_user = params.get("ipa_user", "admin")
    validate_certs = params.get("validate_certs", True)

    # Build base URL
    base_url = ipa_prot + "://" + ipa_host
    if ipa_port != 80 and ipa_port != 443:
        base_url = base_url + ":" + str(ipa_port)
    base_url = base_url + "/ipa/session/json"

    # Login
    if ipa_pass == None:
        fail("ipa_pass is required when not using GSSAPI")
    login_data = '{"method":"login","params":[[],{"user":"' + ipa_user + '","password":"' + ipa_pass + '"}]}'
    curl_args = [
        "curl", "-s", "-k", "--tlsv1.2", "--proto", "=https",
        "--connect-timeout", str(ipa_timeout),
        "-H", "Content-Type: application/json",
        "-d", login_data,
        base_url
    ]
    if not validate_certs:
        curl_args.insert(5, "-k")
    login_res = ctx.run(curl_args, mutates=False)
    if login_res.rc != 0:
        fail("login failed: " + login_res.stderr)

    # Extract session cookie
    session_cookie = ""
    for line in login_res.stderr.splitlines():
        if "Set-Cookie:" in line:
            parts = line.split("ipa_session=")
            if len(parts) > 1:
                session_cookie = parts[1].split(";")[0]
                break
    if session_cookie == "":
        fail("login: failed to retrieve IPA session cookie")

    # Helper to call IPA JSON API
    def ipa_post(method, item=None):
        data = '{"method":"' + method + '","params":[null'
        if item != None:
            json_item = "{"
            for k, v in item.items():
                if isinstance(v, list):
                    json_item = json_item + '"' + k + '":['
                    for i, elem in enumerate(v):
                        if i > 0:
                            json_item = json_item + ","
                        json_item = json_item + '"' + elem + '"'
                    json_item = json_item + "]"
                else:
                    json_item = json_item + '"' + k + '":"'
                    # Simple escaping for double quotes and backslashes
                    escaped = ""
                    for c in v:
                        if c == '"':
                            escaped = escaped + '\\"'
                        elif c == '\\':
                            escaped = escaped + '\\\\'
                        else:
                            escaped = escaped + c
                    json_item = json_item + escaped + '"'
            json_item = json_item + "}"
            data = data + "," + json_item
        data = data + "]}"

        curl_args = [
            "curl", "-s", "-k", "--tlsv1.2", "--proto", "=https",
            "--connect-timeout", str(ipa_timeout),
            "-H", "Content-Type: application/json",
            "-H", "Cookie: ipa_session=" + session_cookie,
            "-d", data,
            base_url
        ]
        if not validate_certs:
            curl_args.insert(5, "-k")
        res = ctx.run(curl_args, mutates=True)
        if res.rc != 0:
            fail("IPA API " + method + " failed: " + res.stderr)
        return res.stdout

    # Find existing group
    find_resp = ipa_post("sudocmdgroup_find", {"all": True, "cn": cn})
    ipa_group = None
    if '"result":[' in find_resp:
        start_idx = find_resp.find('"result":[')
        bracket_idx = find_resp.find('[', start_idx)
        if bracket_idx != -1:
            obj_start = find_resp.find('{', bracket_idx)
            if obj_start != -1:
                depth = 0
                end_idx = -1
                for i in range(obj_start, len(find_resp)):
                    if find_resp[i] == '{':
                        depth = depth + 1
                    elif find_resp[i] == '}':
                        depth = depth - 1
                        if depth == 0:
                            end_idx = i + 1
                            break
                if end_idx != -1:
                    obj_str = find_resp[obj_start:end_idx]
                    if '"cn":' in obj_str and cn in obj_str:
                        ipa_group = obj_str

    # Build desired state data
    desired = {}
    if description != None:
        desired["description"] = description
    if sudocmd != None:
        desired["member_sudocmd"] = sudocmd

    changed = False
    if state == "present":
        if ipa_group == None:
            # Create group
            changed = True
            if not ctx.check_mode:
                ipa_post("sudocmdgroup_add", {"cn": [cn]})
                if description != None:
                    ipa_post("sudocmdgroup_mod", {"cn": [cn], "description": [description]})
                if sudocmd != None:
                    for cmd in sudocmd:
                        ipa_post("sudocmdgroup_add_member_sudocmd", {"cn": [cn], "sudocmd": [cmd]})
        else:
            # Update group
            desc_changed = False
            if description != None:
                if '"description":' not in ipa_group or description not in ipa_group:
                    desc_changed = True
            if desc_changed:
                changed = True
                if not ctx.check_mode:
                    ipa_post("sudocmdgroup_mod", {"cn": [cn], "description": [description]})

            # Compare sudocmds
            if sudocmd != None:
                # Extract existing sudocmds (naive)
                existing_cmds = []
                if '"member_sudocmd":[' in ipa_group:
                    start = ipa_group.find('"member_sudocmd":[')
                    inner = ipa_group[start+len('"member_sudocmd":['):]
                    end = inner.find(']')
                    if end != -1:
                        inner_list = inner[:end]
                        if inner_list.strip() != "":
                            existing_cmds = []
                            for item in inner_list.split(','):
                                item = item.strip()
                                if item.startswith('"') and item.endswith('"'):
                                    item = item[1:-1]
                                if item != "":
                                    existing_cmds.append(item)

                to_add = []
                for cmd in sudocmd:
                    if cmd not in existing_cmds:
                        to_add.append(cmd)

                to_remove = []
                for cmd in existing_cmds:
                    if cmd not in sudocmd:
                        to_remove.append(cmd)

                if len(to_add) > 0 or len(to_remove) > 0:
                    changed = True
                    if not ctx.check_mode:
                        for cmd in to_add:
                            ipa_post("sudocmdgroup_add_member_sudocmd", {"cn": [cn], "sudocmd": [cmd]})
                        for cmd in to_remove:
                            ipa_post("sudocmdgroup_remove_member_sudocmd", {"cn": [cn], "sudocmd": [cmd]})
    elif state == "absent":
        if ipa_group != None:
            changed = True
            if not ctx.check_mode:
                ipa_post("sudocmdgroup_del", {"cn": [cn]})
    else:
        fail("unsupported state: " + state)

    # Final find to return result
    final_resp = ipa_post("sudocmdgroup_find", {"all": True, "cn": cn})
    result = {"changed": changed, "msg": "sudocmdgroup processed"}
    if ctx.check_mode and changed:
        result["msg"] = "would update sudocmdgroup " + cn
    # Return parsed result (minimal extraction)
    if '"result":[' in final_resp:
        start_idx = final_resp.find('"result":[')
        bracket_idx = final_resp.find('[', start_idx)
        if bracket_idx != -1:
            obj_start = final_resp.find('{', bracket_idx)
            if obj_start != -1:
                depth = 0
                end_idx = -1
                for i in range(obj_start, len(final_resp)):
                    if final_resp[i] == '{':
                        depth = depth + 1
                    elif final_resp[i] == '}':
                        depth = depth - 1
                        if depth == 0:
                            end_idx = i + 1
                            break
                if end_idx != -1:
                    result["data"] = {"sudocmdgroup": final_resp[obj_start:end_idx]}
    else:
        result["data"] = {"sudocmdgroup": None}

    return result
