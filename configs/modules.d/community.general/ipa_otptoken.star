def main(ctx, params):
    uniqueid = params["uniqueid"]
    state = params.get("state", "present")
    newuniqueid = params.get("newuniqueid")
    otptype = params.get("otptype")
    secretkey = params.get("secretkey")
    description = params.get("description")
    owner = params.get("owner")
    enabled = params.get("enabled", True)
    notbefore = params.get("notbefore")
    notafter = params.get("notafter")
    vendor = params.get("vendor")
    model = params.get("model")
    serial = params.get("serial")
    algorithm = params.get("algorithm")
    digits = params.get("digits")
    offset = params.get("offset")
    interval = params.get("interval")
    counter = params.get("counter")

    ipa_host = params.get("ipa_host", "ipa.example.com")
    ipa_port = params.get("ipa_port", 443)
    ipa_prot = params.get("ipa_prot", "https")
    ipa_user = params.get("ipa_user", "admin")
    ipa_pass = params.get("ipa_pass")
    ipa_timeout = params.get("ipa_timeout", 10)
    validate_certs = params.get("validate_certs", True)

    if not ipa_pass:
        fail("ipa_pass is required when not using GSSAPI")

    if otptype != None and otptype not in ["totp", "hotp"]:
        fail("otptype must be one of: totp, hotp")
    if algorithm != None and algorithm not in ["sha1", "sha256", "sha384", "sha512"]:
        fail("algorithm must be one of: sha1, sha256, sha384, sha512")
    if digits != None and digits not in [6, 8]:
        fail("digits must be 6 or 8")

    if ipa_prot == "http":
        base_url = "http://" + ipa_host + ":" + str(ipa_port) + "/ipa"
    else:
        base_url = "https://" + ipa_host + ":" + str(ipa_port) + "/ipa"

    def json_str(s):
        if s == None:
            return "null"
        s = str(s)
        s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        return '"' + s + '"'

    def build_json(params_dict):
        items = []
        for k in sorted(params_dict.keys()):
            v = params_dict[k]
            if v == None:
                items.append(json_str(k) + ": null")
            elif type(v) == type(True):
                items.append(json_str(k) + ": " + ("true" if v else "false"))
            elif type(v) == type(0):
                items.append(json_str(k) + ": " + str(v))
            else:
                items.append(json_str(k) + ": " + json_str(v))
        return "{" + ", ".join(items) + "}"

    find_cmd_base = [
        "curl", "-sS", "-f", "-X", "POST",
        "--connect-timeout", str(ipa_timeout),
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "-b", "/tmp/ipa_cookie", "-c", "/tmp/ipa_cookie",
        base_url + "/session/json",
    ]
    if not validate_certs:
        find_cmd_base.append("-k")

    find_payload = build_json({
        "method": "otptoken_find",
        "params": [[], {"all": True, "ipatokenuniqueid": uniqueid, "timelimit": "0", "sizelimit": "0"}],
        "id": 0
    })

    find_res = ctx.run(find_cmd_base + ["--data-binary", find_payload], mutates=False)
    if find_res.rc != 0 and "401" in find_res.stderr:
        fail("Failed to authenticate to IPA: invalid credentials or kerberos not available")
    if find_res.rc != 0:
        fail("IPA otptoken_find failed: " + find_res.stderr)

    find_stdout = find_res.stdout.strip()
    token = None
    if find_stdout.find('"result":') != -1:
        start_idx = find_stdout.find('"result":') + len('"result":')
        if start_idx < len(find_stdout) and find_stdout[start_idx] == '[':
            depth = 0
            i = start_idx
            while i < len(find_stdout) and (depth > 0 or find_stdout[i] != ']'):
                if find_stdout[i] == '[':
                    depth += 1
                elif find_stdout[i] == ']':
                    depth -= 1
                i += 1
            if i < len(find_stdout):
                result_str = find_stdout[start_idx + 1:i]
                if result_str.strip() != "":
                    token = parse_ipa_token(result_str)

    def parse_ipa_token(result_str):
        res = {}
        fields_to_parse = [
            "ipatokenuniqueid", "ipatokenowner", "ipatokendisabled", "description",
            "ipatokenvendor", "ipatokenmodel", "ipatokenserial", "ipatokennotbefore",
            "ipatokennotafter", "type", "ipatokenotpkey", "ipatokenotpalgorithm",
            "ipatokenotpdigits", "ipatokentotpclockoffset", "ipatokentotptimestep",
            "ipatokenhotpcounter"
        ]
        for f in fields_to_parse:
            pattern = f + '":'
            idx = result_str.find(pattern)
            if idx == -1:
                continue
            idx += len(pattern)
            while idx < len(result_str) and result_str[idx] in [" ", "\t"]:
                idx += 1
            if idx >= len(result_str):
                continue
            if result_str[idx] != '[':
                continue
            idx += 1
            depth = 0
            j = idx
            while j < len(result_str) and (depth > 0 or result_str[j] != ']'):
                if result_str[j] == '[':
                    depth += 1
                elif result_str[j] == ']':
                    depth -= 1
                elif result_str[j] == '"':
                    j += 1
                    while j < len(result_str) and result_str[j] != '"':
                        if result_str[j] == '\\' and j + 1 < len(result_str):
                            j += 1
                        j += 1
                j += 1
            if j >= len(result_str):
                continue
            inner = result_str[idx:j]
            inner = inner.strip()
            if inner == "":
                res[f] = []
                continue
            if inner[0] == '"':
                i = 1
                while i < len(inner) and inner[i] != '"':
                    if inner[i] == '\\' and i + 1 < len(inner):
                        i += 1
                    i += 1
                if i < len(inner):
                    val = inner[1:i]
                    val = val.replace("\\n", "\n").replace("\\t", "\t").replace("\\r", "\r")
                    res[f] = [val]
                else:
                    res[f] = []
            else:
                i = 0
                while i < len(inner) and (inner[i].isdigit() or inner[i] in ["-", "+", "."]):
                    i += 1
                if i > 0:
                    res[f] = [inner[0:i]]
                else:
                    res[f] = []
        return res

    def build_mod_dict():
        d = {}
        if otptype != None:
            d["type"] = otptype.upper()
        if secretkey != None:
            fail("secretkey conversion (base64 -> base32) not supported in Starlark")
        if description != None:
            d["description"] = description
        if owner != None:
            d["ipatokenowner"] = owner
        if enabled != None:
            d["ipatokendisabled"] = "FALSE" if enabled else "TRUE"
        if notbefore != None:
            d["ipatokennotbefore"] = notbefore + "Z"
        if notafter != None:
            d["ipatokennotafter"] = notafter + "Z"
        if vendor != None:
            d["ipatokenvendor"] = vendor
        if model != None:
            d["ipatokenmodel"] = model
        if serial != None:
            d["ipatokenserial"] = serial
        if algorithm != None:
            d["ipatokenotpalgorithm"] = algorithm
        if digits != None:
            d["ipatokenotpdigits"] = str(digits)
        if offset != None:
            d["ipatokentotpclockoffset"] = str(offset)
        if interval != None:
            d["ipatokentotptimestep"] = str(interval)
        if counter != None:
            d["ipatokenhotpcounter"] = str(counter)
        if newuniqueid != None:
            d["rename"] = newuniqueid
        return d

    unmodifiable = ["type", "ipatokenotpkey", "ipatokenotpalgorithm", "ipatokenotpdigits",
                    "ipatokentotpclockoffset", "ipatokentotptimestep", "ipatokenhotpcounter"]

    changed = False
    msg = ""

    if state == "present":
        if token == None:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would create otptoken " + uniqueid}

            mod_dict = build_mod_dict()
            mod_dict["all"] = True
            current_uniqueid = uniqueid
            if "rename" in mod_dict:
                current_uniqueid = mod_dict["rename"]
                # Remove rename key properly (no del)
                # Create new dict without rename
                new_mod_dict = {}
                for k in mod_dict:
                    if k != "rename":
                        new_mod_dict[k] = mod_dict[k]
                mod_dict = new_mod_dict

            add_cmd_base = [
                "curl", "-sS", "-f", "-X", "POST",
                "--connect-timeout", str(ipa_timeout),
                "-H", "Content-Type: application/json",
                "-H", "Accept: application/json",
                "-b", "/tmp/ipa_cookie", "-c", "/tmp/ipa_cookie",
            ]
            if not validate_certs:
                add_cmd_base.append("-k")

            add_payload = build_json({
                "method": "otptoken_add",
                "params": [[current_uniqueid], mod_dict],
                "id": 0
            })
            add_res = ctx.run(add_cmd_base + [base_url + "/session/json", "--data-binary", add_payload], mutates=True)
            if add_res.skipped:
                return {"changed": True, "msg": "would create otptoken " + current_uniqueid}
            if add_res.rc != 0:
                fail("ipa otptoken_add failed: " + add_res.stderr)
            msg = "created otptoken " + current_uniqueid
        else:
            mod_dict = build_mod_dict()
            for f in unmodifiable:
                if f in mod_dict:
                    del_key = f
                    new_mod_dict = {}
                    for k in mod_dict:
                        if k != del_key:
                            new_mod_dict[k] = mod_dict[k]
                    mod_dict = new_mod_dict

            needs_update = False
            for k in mod_dict:
                v = mod_dict[k]
                if k not in token or len(token[k]) == 0:
                    needs_update = True
                    break
                if str(token[k][0]) != str(v):
                    needs_update = True
                    break

            if needs_update:
                changed = True
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update otptoken " + uniqueid}

                mod_dict["all"] = True
                current_uniqueid = uniqueid
                rename_value = None
                if "rename" in mod_dict:
                    rename_value = mod_dict["rename"]
                    new_mod_dict = {}
                    for k in mod_dict:
                        if k != "rename":
                            new_mod_dict[k] = mod_dict[k]
                    mod_dict = new_mod_dict
                    current_uniqueid = rename_value

                mod_cmd_base = [
                    "curl", "-sS", "-f", "-X", "POST",
                    "--connect-timeout", str(ipa_timeout),
                    "-H", "Content-Type: application/json",
                    "-H", "Accept: application/json",
                    "-b", "/tmp/ipa_cookie", "-c", "/tmp/ipa_cookie",
                ]
                if not validate_certs:
                    mod_cmd_base.append("-k")

                mod_payload = build_json({
                    "method": "otptoken_mod",
                    "params": [[uniqueid], mod_dict],
                    "id": 0
                })
                mod_res = ctx.run(mod_cmd_base + [base_url + "/session/json", "--data-binary", mod_payload], mutates=True)
                if mod_res.skipped:
                    return {"changed": True, "msg": "would update otptoken " + uniqueid}
                if mod_res.rc != 0:
                    fail("ipa otptoken_mod failed: " + mod_res.stderr)
                msg = "updated otptoken " + current_uniqueid
            else:
                msg = "otptoken " + uniqueid + " already in desired state"
    else:
        if token != None:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete otptoken " + uniqueid}

            del_cmd_base = [
                "curl", "-sS", "-f", "-X", "POST",
                "--connect-timeout", str(ipa_timeout),
                "-H", "Content-Type: application/json",
                "-H", "Accept: application/json",
                "-b", "/tmp/ipa_cookie", "-c", "/tmp/ipa_cookie",
            ]
            if not validate_certs:
                del_cmd_base.append("-k")

            del_payload = build_json({
                "method": "otptoken_del",
                "params": [[uniqueid], {}],
                "id": 0
            })
            del_res = ctx.run(del_cmd_base + [base_url + "/session/json", "--data-binary", del_payload], mutates=True)
            if del_res.skipped:
                return {"changed": True, "msg": "would delete otptoken " + uniqueid}
            if del_res.rc != 0:
                fail("ipa otptoken_del failed: " + del_res.stderr)
            msg = "deleted otptoken " + uniqueid
        else:
            msg = "otptoken " + uniqueid + " already absent"

    return {"changed": changed, "msg": msg}
