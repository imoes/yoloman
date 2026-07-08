def main(ctx, params):
    fqdn = params["fqdn"]
    state = params.get("state", "present")
    description = params.get("description")
    force = params.get("force")
    ip_address = params.get("ip_address")
    ns_host_location = params.get("ns_host_location")
    ns_hardware_platform = params.get("ns_hardware_platform")
    ns_os_version = params.get("ns_os_version")
    mac_address = params.get("mac_address")
    user_certificate = params.get("user_certificate")
    update_dns = params.get("update_dns", False)
    random_password = params.get("random_password")
    ipa_host = params.get("ipa_host", "ipa.example.com")
    ipa_port = params.get("ipa_port", 443)
    ipa_prot = params.get("ipa_prot", "https")
    ipa_user = params.get("ipa_user", "admin")
    ipa_pass = params.get("ipa_pass")
    validate_certs = params.get("validate_certs", True)

    if ipa_pass == None:
        fail("ipa_pass is required (no environment variable support in Starlark)")

    # Build base URL
    proto = "https" if ipa_prot == "https" else "http"
    base_url = proto + "://" + ipa_host + ":" + str(ipa_port) + "/ipa/json"

    # Helper: escape string for JSON
    def _json_escape(s):
        s = str(s)
        s = s.replace("\\", "\\\\")
        s = s.replace("\"", "\\\"")
        s = s.replace("\n", "\\n")
        s = s.replace("\r", "\\r")
        s = s.replace("\t", "\\t")
        return s

    # Helper: serialize simple value to JSON (no imports, no json module)
    def _json_serialize(obj):
        if obj == None:
            return "null"
        elif type(obj) == "bool":
            return "true" if obj else "false"
        elif type(obj) == "int":
            return str(obj)
        elif type(obj) == "string":
            return "\"" + _json_escape(obj) + "\""
        elif type(obj) == "list":
            items = []
            for x in obj:
                items.append(_json_serialize(x))
            return "[" + ", ".join(items) + "]"
        elif type(obj) == "dict":
            kv_pairs = []
            for k in obj:
                v = obj[k]
                kv_pairs.append("\"" + _json_escape(k) + "\": " + _json_serialize(v))
            return "{" + ", ".join(kv_pairs) + "}"
        else:
            fail("unsupported JSON type: " + type(obj))

    # Helper: POST to IPA JSON API
    def ipa_post(method, params_dict, mutates):
        body = "{\"method\":\"" + method + "\",\"params\":[null," + _json_serialize(params_dict) + "],\"id\":0}"
        url = base_url
        curl_args = ["curl", "-s", "-k", "-X", "POST", "-H", "Content-Type: application/json", "-H", "Accept: application/json", "-d", body, url]
        if not validate_certs:
            curl_args = ["curl", "-s", "-k", "-X", "POST", "-H", "Content-Type: application/json", "-H", "Accept: application/json", "-d", body, url]
        res = ctx.run(curl_args, mutates=mutates)
        if res.skipped:
            return None
        if res.rc != 0:
            fail("IPA request failed: " + res.stderr)
        output = res.stdout.strip()
        # Find the last { and matching }
        start_idx = output.find("{")
        if start_idx < 0:
            fail("Invalid IPA response: " + output)
        end_idx = output.rfind("}")
        if end_idx <= start_idx:
            fail("Invalid IPA response: " + output)
        output = output[start_idx:end_idx + 1]

        # Manual dict parse — safe subset only
        def _parse_dict(s):
            s = s.strip()
            if not s.startswith("{") or not s.endswith("}"):
                fail("Not a dict: " + s)
            inner = s[1:-1].strip()
            if inner == "":
                return {}
            result = {}
            # Split on top-level commas
            depth = 0
            current = []
            parts = []
            for ch in inner:
                if ch == "{" or ch == "[":
                    depth += 1
                elif ch == "}" or ch == "]":
                    depth -= 1
                if ch == "," and depth == 0:
                    parts.append("".join(current).strip())
                    current = []
                else:
                    current.append(ch)
            if len(current) > 0:
                parts.append("".join(current).strip())
            for part in parts:
                idx = part.find(":")
                if idx < 0:
                    fail("Bad dict part: " + part)
                k = part[:idx].strip().strip("\"")
                v = part[idx + 1:].strip()
                if v.startswith("\"") and v.endswith("\""):
                    v = v[1:-1]
                elif v == "true":
                    v = True
                elif v == "false":
                    v = False
                elif v == "null":
                    v = None
                elif v.startswith("[") and v.endswith("]"):
                    v = v[1:-1].split(",")
                    v = [x.strip().strip("\"") for x in v if x.strip()]
                result[k] = v
            return result
        return _parse_dict(output)

    # Login (session cookie via curl)
    login_url = base_url + "/session/json"
    login_body = "{\"method\":\"login\",\"params\":[null,{\"user\":\"" + _json_escape(ipa_user) + "\",\"password\":\"" + _json_escape(ipa_pass) + "\"}],\"id\":0}"
    res = ctx.run(["curl", "-s", "-c", "/dev/null", "-X", "POST", "-H", "Content-Type: application/json", "-H", "Accept: application/json", "-d", login_body, login_url], mutates=False)
    if res.rc != 0:
        fail("Login failed: " + res.stderr)

    # host_find to check existence
    find_params = {"version": "2.240", "all": True, "fqdn": fqdn}
    res_dict = ipa_post("host_find", find_params, mutates=False)
    entries = []
    if res_dict != None and type(res_dict) == "dict":
        if "result" in res_dict and type(res_dict["result"]) == "list":
            entries = res_dict["result"]
    ipa_host = None
    for entry in entries:
        if type(entry) == "dict" and entry.get("fqdn") == fqdn:
            ipa_host = entry
            break

    changed = False
    host_result = {}

    if state in ["present", "enabled", "disabled"]:
        # Prepare module_host dict
        module_host = {}
        if description != None:
            module_host["description"] = description
        if force != None:
            module_host["force"] = force
        if ip_address != None:
            module_host["ip_address"] = ip_address
        if ns_host_location != None:
            module_host["nshostlocation"] = ns_host_location
        if ns_hardware_platform != None:
            module_host["nshardwareplatform"] = ns_hardware_platform
        if ns_os_version != None:
            module_host["nsosversion"] = ns_os_version
        if mac_address != None:
            module_host["macaddress"] = mac_address
        if user_certificate != None:
            module_host["usercertificate"] = []
            for cert in user_certificate:
                module_host["usercertificate"].append({"__base64__": cert})
        if random_password != None:
            module_host["random"] = random_password

        if ipa_host == None:
            # Create host
            if ctx.check_mode:
                return {"changed": True, "msg": "would add host " + fqdn}
            add_params = {"version": "2.240"}
            for k in module_host:
                add_params[k] = module_host[k]
            res_dict = ipa_post("host_add", add_params, mutates=True)
            if res_dict == None:
                fail("host_add failed: no cookie support")
            changed = True
            host_result = res_dict.get("result", {})
            return {"changed": True, "msg": "host added", "data": host_result}

        else:
            # Compute diff: exclude non-updatable keys
            non_updateable = ["force", "ip_address"]
            if not module_host.get("random"):
                non_updateable.append("random")
            mod_host = {}
            for k in module_host:
                if not (k in non_updateable):
                    mod_host[k] = module_host[k]

            # Diff: compare with ipa_host (simplified)
            diff = []
            for k in mod_host:
                if not (k in ipa_host):
                    diff.append(k)
                elif str(ipa_host[k]) != str(mod_host[k]):
                    diff.append(k)

            if len(diff) > 0:
                changed = True
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update host " + fqdn}
                # Prepare mod data
                mod_data = {}
                for k in diff:
                    mod_data[k] = mod_host[k]

                # Handle keytab disable if needed
                if ipa_host.get("has_keytab") and module_host.get("random"):
                    ipa_post("host_disable", {"version": "2.240", "cn": [fqdn]}, mutates=True)

                mod_params = {"version": "2.240"}
                for k in mod_data:
                    mod_params[k] = mod_data[k]
                res_dict = ipa_post("host_mod", mod_params, mutates=True)
                if res_dict == None:
                    fail("host_mod failed: no cookie support")
                host_result = res_dict.get("result", {})
                return {"changed": True, "msg": "host updated", "data": host_result}

    elif state == "absent":
        if ipa_host != None:
            changed = True
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete host " + fqdn}
            del_params = {"version": "2.240", "updatedns": update_dns}
            res_dict = ipa_post("host_del", del_params, mutates=True)
            if res_dict == None:
                fail("host_del failed: no cookie support")
            host_result = res_dict.get("result", {})
            return {"changed": True, "msg": "host deleted", "data": host_result}

    return {"changed": False, "msg": "host already in desired state", "data": ipa_host}
