def main(ctx, params):
    cn = params["cn"]
    description = params.get("description")
    group = params.get("group")
    host = params.get("host")
    hostgroup = params.get("hostgroup")
    privilege = params.get("privilege")
    service = params.get("service")
    user = params.get("user")
    state = params.get("state", "present")
    ipa_host = params.get("ipa_host", "ipa.example.com")
    ipa_port = params.get("ipa_port", 443)
    ipa_prot = params.get("ipa_prot", "https")
    ipa_timeout = params.get("ipa_timeout", 10)
    ipa_user = params.get("ipa_user", "admin")
    ipa_pass = params.get("ipa_pass")
    validate_certs = params.get("validate_certs", True)

    # Build IPA API base URL
    base_url = ipa_prot + "://" + ipa_host + ":" + str(ipa_port) + "/ipa/session/json"

    # Helper to run IPA commands via curl
    def ipa_post_json(method, name, item):
        payload_str = '{"method": "%s", "params": [[%s], %s], "id": 0}' % (method, 'null' if name == None else '"' + name + '"', str(item))
        headers = [
            "-H", "Content-Type: application/json",
            "-H", "Accept: application/json",
            "--tlsv1.2"
        ]
        insecure_flag = ["--insecure"] if not validate_certs else []
        cookie_jar = [ "--cookie-jar", "/tmp/ipa_cookie" ]
        curl_args = ["curl", "-s"] + headers + insecure_flag + cookie_jar + [ "-d", payload_str, base_url ]
        res = ctx.run(curl_args, mutates=True)
        if res.rc != 0:
            fail("IPA API call failed: " + res.stderr)
        return res.stdout

    # Perform login
    if ipa_pass == None:
        fail("ipa_pass is required when not using GSSAPI (no KRB5CCNAME)")
    login_payload = '{"method": "login", "params": [[], {"user": "%s", "password": "%s"}], "id": 0}' % (ipa_user, ipa_pass)
    login_res = ctx.run([
        "curl", "-s", "-H", "Content-Type: application/json", "-H", "Accept: application/json",
        "--tlsv1.2", "--cookie-jar", "/tmp/ipa_cookie",
        "-d", login_payload, base_url
    ], mutates=False)
    if login_res.rc != 0:
        fail("IPA login failed: " + login_res.stderr)

    # Helper to run IPA role_find
    def role_find(name):
        item = {"all": True, "cn": name}
        return ipa_post_json("role_find", None, item)

    # Helper to run IPA role_add
    def role_add(name, item):
        return ipa_post_json("role_add", name, item)

    # Helper to run IPA role_mod
    def role_mod(name, item):
        return ipa_post_json("role_mod", name, item)

    # Helper to run IPA role_del
    def role_del(name):
        return ipa_post_json("role_del", name, [])

    # Helper to add members
    def role_add_member(name, member_type, member_list):
        item = {"member_%s" % member_type: member_list}
        return ipa_post_json("role_add_member", name, item)

    # Helper to remove members
    def role_remove_member(name, member_type, member_list):
        item = {"member_%s" % member_type: member_list}
        return ipa_post_json("role_remove_member", name, item)

    # Helper to add privileges
    def role_add_privilege(name, privilege_list):
        item = {"member_privilege": privilege_list}
        return ipa_post_json("role_add_privilege", name, item)

    # Helper to remove privileges
    def role_remove_privilege(name, privilege_list):
        item = {"member_privilege": privilege_list}
        return ipa_post_json("role_remove_privilege", name, item)

    # Helper to compare lists (set equality ignoring order)
    def lists_equal(a, b):
        if a == None or b == None:
            return a == b
        if type(a) != "list" or type(b) != "list":
            return False
        if len(a) != len(b):
            return False
        sorted_a = sorted(a)
        sorted_b = sorted(b)
        for i in range(len(sorted_a)):
            if sorted_a[i] != sorted_b[i]:
                return False
        return True

    # Get current role state
    ipa_role_raw = role_find(cn)

    # Very basic parsing to detect existence
    ipa_role_exists = ipa_role_raw.find('"description":') != -1 or ipa_role_raw.find('"cn":') != -1

    # Extract description
    ipa_role_desc = None
    if ipa_role_raw.find('"description":') != -1:
        desc_start = ipa_role_raw.find('"description":') + len('"description":')
        desc_rest = ipa_role_raw[desc_start:]
        # Extract quoted string
        if desc_rest[0] == '"':
            end_quote = desc_rest.find('"', 1)
            if end_quote != -1:
                ipa_role_desc = desc_rest[1:end_quote]

    # Parse member lists from raw JSON string
    ipa_members = {
        "group": [],
        "host": [],
        "hostgroup": [],
        "privilege": [],
        "service": [],
        "user": []
    }

    for member_type in ipa_members.keys():
        key = '"member_%s": [' % member_type
        start = ipa_role_raw.find(key)
        if start != -1:
            rest = ipa_role_raw[start + len(key):]
            # Find closing bracket
            bracket_depth = 1
            end = 0
            for i in range(len(rest)):
                if rest[i] == '[':
                    bracket_depth += 1
                elif rest[i] == ']':
                    bracket_depth -= 1
                if bracket_depth == 0:
                    end = i
                    break
            list_str = rest[:end].strip()
            # Extract each quoted string
            items = []
            pos = 0
            while pos < len(list_str):
                pos = list_str.find('"', pos)
                if pos == -1:
                    break
                end_pos = list_str.find('"', pos + 1)
                if end_pos == -1:
                    break
                items.append(list_str[pos + 1:end_pos])
                pos = end_pos + 1
            ipa_members[member_type] = items

    # Build desired state
    module_role_desc = description
    desired_members = {
        "group": group if group != None else [],
        "host": host if host != None else [],
        "hostgroup": hostgroup if hostgroup != None else [],
        "privilege": privilege if privilege != None else [],
        "service": service if service != None else [],
        "user": user if user != None else []
    }

    changed = False
    msg = ""

    if state == "present":
        # Check if role exists
        if not ipa_role_exists:
            changed = True
            if not ctx.check_mode:
                item = {}
                if description != None:
                    item["description"] = description
                role_add(cn, item)
            msg = "role %s would be created" % cn if ctx.check_mode else "role %s created" % cn
        else:
            # Check description diff
            if module_role_desc != ipa_role_desc:
                changed = True
                if not ctx.check_mode:
                    data = {}
                    if description != None:
                        data["description"] = description
                    role_mod(cn, data)
                msg = "role %s would be updated" % cn if ctx.check_mode else "role %s updated" % cn

        # Check members
        for member_type in desired_members.keys():
            desired = desired_members[member_type]
            current = ipa_members[member_type]
            if not lists_equal(desired, current):
                changed = True
                if not ctx.check_mode:
                    # Determine adds and removes
                    to_add = [item for item in desired if item not in current]
                    to_remove = [item for item in current if item not in desired]
                    if member_type == "privilege":
                        if len(to_add) > 0:
                            role_add_privilege(cn, to_add)
                        if len(to_remove) > 0:
                            role_remove_privilege(cn, to_remove)
                    else:
                        if len(to_add) > 0:
                            role_add_member(cn, member_type, to_add)
                        if len(to_remove) > 0:
                            role_remove_member(cn, member_type, to_remove)
                msg = "role %s members would be updated" % cn if ctx.check_mode else "role %s members updated" % cn

        if not changed:
            msg = "role %s already exists with correct settings" % cn

    else:  # absent
        if ipa_role_exists:
            changed = True
            if not ctx.check_mode:
                role_del(cn)
            msg = "role %s would be deleted" % cn if ctx.check_mode else "role %s deleted" % cn
        else:
            msg = "role %s does not exist" % cn

    return {"changed": changed, "msg": msg, "data": {}}
