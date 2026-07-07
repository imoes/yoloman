def main(ctx, params):
    sudocmd = params["sudocmd"]
    description = params.get("description")
    state = params.get("state", "present")
    host = params.get("ipa_host", "ipa.example.com")
    port = params.get("ipa_port", 443)
    protocol = params.get("ipa_prot", "https")
    timeout = params.get("ipa_timeout", 10)
    user = params.get("ipa_user", "admin")
    password = params.get("ipa_pass")
    validate_certs = params.get("validate_certs", True)

    if state not in ("present", "absent", "enabled", "disabled"):
        fail("unsupported state: " + state)

    if state in ("enabled", "disabled"):
        fail("state " + state + " not supported for ipa_sudocmd")

    # Build base URL
    base_url = protocol + "://" + host + ":" + str(port) + "/ipa/session/json"

    # Prepare auth headers if password provided; otherwise fail (GSSAPI unsupported in Starlark)
    if password == None:
        fail("ipa_pass is required in Starlark implementation (GSSAPI not supported)")

    # Helper: escape string for JSON
    def json_str(s):
        if s == None:
            return "null"
        if isinstance(s, bool):
            return "true" if s else "false"
        if isinstance(s, int) or isinstance(s, float):
            return str(s)
        if isinstance(s, str):
            escaped = ""
            for c in s:
                if c == '"':
                    escaped = escaped + "\\\""
                elif c == '\\':
                    escaped = escaped + "\\\\"
                elif c == '\n':
                    escaped = escaped + "\\n"
                elif c == '\r':
                    escaped = escaped + "\\r"
                elif c == '\t':
                    escaped = escaped + "\\t"
                else:
                    escaped = escaped + c
            return "\"" + escaped + "\""
        fail("unsupported type for json_str: " + str(type(s)))

    # Helper: build JSON object string
    def json_obj(d):
        if d == None:
            return "null"
        items = []
        for k, v in d.items():
            items.append(json_str(k) + ":" + json_obj(v))
        return "{" + ",".join(items) + "}"

    # Helper: build JSON array string
    def json_arr(l):
        if l == None:
            return "null"
        items = []
        for item in l:
            items.append(json_obj(item))
        return "[" + ",".join(items) + "]"

    # Perform IPA JSON request
    def ipa_request(method, params_list, item_dict):
        payload = {"method": method, "params": [params_list, item_dict]}
        json_payload = json_obj(payload)
        res = ctx.run([
            "curl", "-s", "-k",
            "-H", "Content-Type: application/json",
            "-H", "Accept: application/json",
            "-H", "Referer: " + base_url,
            "-d", json_payload,
            "-b", "/dev/null", "-c", "/dev/null",
            base_url
        ], mutates=True)
        if res.rc != 0:
            fail("IPA request failed: " + res.stderr)
        return res.stdout

    # Login using password
    login_payload = {"user": user, "password": password}
    ipa_request("login", [], login_payload)

    # Find sudo command
    def sudocmd_find(name):
        item = {"all": True, "sudocmd": name}
        stdout = ipa_request("sudocmd_find", [[], item], {})
        # Naive extraction of 'result'
        if '"result":' in stdout:
            idx = stdout.find('"result":') + len('"result":')
            rest = stdout[idx:].strip()
            if rest.startswith('['):
                # Extract first element object
                depth = 0
                start = -1
                for i, c in enumerate(rest):
                    if c == '{':
                        if depth == 0:
                            start = i
                        depth += 1
                    elif c == '}':
                        depth -= 1
                        if depth == 0 and start >= 0:
                            return [rest[start:i+1]]
                return []
        return []

    # Add sudo command
    def sudocmd_add(name, item_dict):
        ipa_request("sudocmd_add", [[name], {}], item_dict)

    # Modify sudo command
    def sudocmd_mod(name, item_dict):
        ipa_request("sudocmd_mod", [[name], {}], item_dict)

    # Delete sudo command
    def sudocmd_del(name):
        ipa_request("sudocmd_del", [[name], {}], {})

    # Probe current state
    ipa_sudocmd = sudocmd_find(sudocmd)
    ipa_exists = len(ipa_sudocmd) > 0
    ipa_desc = None
    if ipa_exists:
        obj_str = ipa_sudocmd[0]
        if '"description":' in obj_str:
            idx = obj_str.find('"description":') + len('"description":')
            rest = obj_str[idx:].strip()
            if rest.startswith('"'):
                end = rest.find('"', 1)
                if end != -1:
                    ipa_desc = rest[1:end]

    module_sudocmd_desc = description

    changed = False
    if state == "present":
        if not ipa_exists:
            changed = True
            if not ctx.check_mode:
                item = {}
                if module_sudocmd_desc != None:
                    item["description"] = module_sudocmd_desc
                sudocmd_add(sudocmd, item)
        else:
            if ipa_desc != module_sudocmd_desc:
                changed = True
                if not ctx.check_mode:
                    item = {}
                    if module_sudocmd_desc != None:
                        item["description"] = module_sudocmd_desc
                    sudocmd_mod(sudocmd, item)
    elif state == "absent":
        if ipa_exists:
            changed = True
            if not ctx.check_mode:
                sudocmd_del(sudocmd)
    else:
        fail("unsupported state: " + state)

    # Return current state (simulate API result)
    current = {}
    if ipa_exists:
        current["sudocmd"] = sudocmd
        if ipa_desc != None:
            current["description"] = ipa_desc
    elif state == "present" and (changed or ctx.check_mode):
        current["sudocmd"] = sudocmd
        if module_sudocmd_desc != None:
            current["description"] = module_sudocmd_desc

    return {"changed": changed, "data": current}
