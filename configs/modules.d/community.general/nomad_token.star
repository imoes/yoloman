def main(ctx, params):
    host = params["host"]
    port = params.get("port", 4646)
    state = params["state"]
    use_ssl = params.get("use_ssl", True)
    timeout = params.get("timeout", 5)
    validate_certs = params.get("validate_certs", True)
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")
    namespace = params.get("namespace")
    token = params.get("token")
    name = params.get("name")
    token_type = params.get("token_type", "client")
    policies = params.get("policies", [])
    global_replicated = params.get("global_replicated", False)

    if state == "absent" and name == None:
        fail("name is needed to delete token.")
    if token_type in ["client", "management"] and name == None:
        fail("name is required when token_type is " + token_type)
    if state == "absent" and (token_type == "bootstrap" or (name != None and name == "Bootstrap Token")):
        fail("Delete ACL bootstrap token is not allowed.")

    scheme = "https" if use_ssl else "http"
    url = scheme + "://" + host + ":" + str(port)

    cert_str = ""
    if client_cert != None and client_key != None:
        cert_str = client_cert + "," + client_key
    elif client_cert != None:
        cert_str = client_cert

    def _run_cmd(args, mutates=False):
        return ctx.run(args, mutates=mutates)

    def _bootstrap_exists():
        args = [
            "curl", "-s", "-k", "-X", "GET",
            url + "/v1/acl/tokens",
            "--connect-timeout", str(timeout)
        ]
        if cert_str != "":
            args.extend(["--cert", cert_str])
        res = _run_cmd(args)
        if res.rc != 0:
            fail("failed to list tokens: " + res.stderr)
        return "Bootstrap Token" in res.stdout

    def _get_token_by_name(n):
        args = [
            "curl", "-s", "-k", "-X", "GET",
            url + "/v1/acl/tokens",
            "--connect-timeout", str(timeout)
        ]
        if cert_str != "":
            args.extend(["--cert", cert_str])
        res = _run_cmd(args)
        if res.rc != 0:
            fail("failed to list tokens: " + res.stderr)
        lines = res.stdout.split("\n")
        for i in range(len(lines)):
            line = lines[i]
            if "\"Name\":" in line and n in line:
                return line
        return None

    def _call_api(method, endpoint, data_json, mutates=False):
        args = [
            "curl", "-s", "-k", "-X", method.upper(),
            url + endpoint,
            "--connect-timeout", str(timeout),
            "-d", data_json
        ]
        if cert_str != "":
            args.extend(["--cert", cert_str])
        res = _run_cmd(args, mutates=mutates)
        if res.rc != 0:
            fail("API call failed: " + res.stderr)
        return res.stdout

    # Bootstrap token creation
    if token_type == "bootstrap":
        if state == "present":
            existing = _bootstrap_exists()
            if existing:
                return {"changed": False, "msg": "ACL bootstrap already exist."}
            if ctx.check_mode:
                return {"changed": True, "msg": "would create bootstrap token."}
            resp = _call_api("POST", "/v1/acl/bootstrap", "{}", mutates=True)
            accessor_id = ""
            idx = resp.find("\"AccessorID\"")
            if idx != -1:
                start = resp.find(":", idx) + 2
                end = resp.find(",", start)
                if end == -1:
                    end = resp.find("}", start)
                accessor_id = resp[start:end].strip().strip("\"")
            return {
                "changed": True,
                "msg": "Bootstrap token created.",
                "data": {"accessor_id": accessor_id, "name": "Bootstrap Token"}
            }

    # Standard token operations
    if state == "present":
        if token_type not in ["client", "management"]:
            fail("token_type must be 'client' or 'management' when state is 'present' and not bootstrap")

        current_token = None
        if name != None:
            current_token = _get_token_by_name(name)

        # Build policies JSON
        policies_json = "["
        for i in range(len(policies)):
            if i > 0:
                policies_json += ","
            policies_json += "\"" + policies[i] + "\""
        policies_json += "]"

        # Determine if update or create
        if current_token != None and current_token.find("\"AccessorID\"") != -1:
            start = current_token.find("\"AccessorID\"") + 13
            end = current_token.find("\"", start)
            if end != -1:
                accessor_id = current_token[start:end]
                # Update payload
                payload = "{"
                payload += "\"AccessorID\":\"" + accessor_id + "\","
                payload += "\"Name\":\"" + name + "\","
                payload += "\"Type\":\"" + token_type + "\","
                payload += "\"Policies\":" + policies_json + ","
                payload += "\"Global\":" + ("true" if global_replicated else "false")
                payload += "}"

                if ctx.check_mode:
                    return {"changed": True, "msg": "would update token."}
                resp = _call_api("POST", "/v1/acl/token", payload, mutates=True)
                return {"changed": True, "msg": "ACL token updated.", "data": resp}

        # Create payload
        payload = "{"
        payload += "\"Name\":\"" + name + "\","
        payload += "\"Type\":\"" + token_type + "\","
        payload += "\"Policies\":" + policies_json + ","
        payload += "\"Global\":" + ("true" if global_replicated else "false")
        payload += "}"

        if ctx.check_mode:
            return {"changed": True, "msg": "would create token."}
        resp = _call_api("POST", "/v1/acl/token", payload, mutates=True)
        return {"changed": True, "msg": "ACL token created.", "data": resp}

    if state == "absent":
        if ctx.check_mode:
            found = _get_token_by_name(name) != None
            msg = "No token with name '%s' found" % name if not found else "would delete token."
            return {"changed": found, "msg": msg}

        token_entry = _get_token_by_name(name)
        if token_entry == None:
            return {"changed": False, "msg": "No token with name '%s' found" % name}

        accessor_id = ""
        idx = token_entry.find("\"AccessorID\"")
        if idx != -1:
            start = token_entry.find(":", idx) + 2
            end = token_entry.find("\"", start)
            if end == -1:
                fail("could not parse AccessorID from token info")
            accessor_id = token_entry[start:end]

        res = _run_cmd([
            "curl", "-s", "-k", "-X", "DELETE",
            url + "/v1/acl/token/" + accessor_id,
            "--connect-timeout", str(timeout)
        ], mutates=True)
        if res.rc != 0:
            fail("failed to delete token: " + res.stderr)
        return {"changed": True, "msg": "ACL token deleted."}
