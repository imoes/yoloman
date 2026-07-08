def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    api_token = params["api_token"]
    api_version = params.get("api_version", 39)
    policy = params.get("policy")
    project = params.get("project")
    url = params["url"]

    # Validation
    if state == "present" and policy == None:
        fail("policy is required when state is present")
    if api_version < 14:
        fail("api_version should be at least 14")
    # Check name characters: allow a-zA-Z0-9,.+_- (without regex module, use manual check)
    valid_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,.+_-"
    for c in name:
        if c not in valid_chars:
            fail("Name contains forbidden characters. The policy can contain the characters: a-zA-Z0-9,.+_-")

    # Build endpoint
    endpoint = "system/acl/" + name + ".aclpolicy"

    # Helper: build request args
    def build_request_args(method, data=None):
        args = {
            "url": url + "/" + endpoint,
            "headers": {
                "X-Rundeck-Auth-Token": api_token,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            "method": method,
        }
        if data != None:
            args["data"] = data
        return args

    # Helper: make HTTP request via url
    def rundeck_request(method, data=None):
        args = build_request_args(method, data)
        # map common options to url module
        url_opts = {}
        if params.get("validate_certs") != None:
            url_opts["validate_certs"] = params["validate_certs"]
        if params.get("use_proxy") != None:
            url_opts["use_proxy"] = params["use_proxy"]
        if params.get("url_username") != None:
            url_opts["url_username"] = params["url_username"]
        if params.get("url_password") != None:
            url_opts["url_password"] = params["url_password"]
        if params.get("force_basic_auth") != None:
            url_opts["force_basic_auth"] = params["force_basic_auth"]
        if params.get("http_agent") != None:
            url_opts["http_agent"] = params["http_agent"]
        if params.get("client_cert") != None:
            url_opts["client_cert"] = params["client_cert"]
        if params.get("client_key") != None:
            url_opts["client_key"] = params["client_key"]

        # Merge in known url options
        for k in url_opts:
            args[k] = url_opts[k]

        return ctx.url_request(args)

    # GET current ACL
    def get_acl():
        res = rundeck_request("GET")
        if res.status == 404:
            return None
        if res.status != 200:
            fail("Failed to get ACL: HTTP %d" % res.status + (": " + res.data if res.data else ""))
        return ctx.json_loads(res.data)

    # STATE: absent
    if state == "absent":
        facts = get_acl()
        if facts == None:
            return {"changed": False, "before": {}, "after": {}}
        if ctx.check_mode:
            return {"changed": True, "before": facts, "after": {}}
        res = rundeck_request("DELETE")
        if res.status != 200 and res.status != 204:
            fail("Failed to delete ACL: HTTP %d" % res.status)
        return {"changed": True, "before": facts, "after": {}}

    # STATE: present
    facts = get_acl()

    # If policy matches, nothing to do
    if facts != None and facts.get("contents") == policy:
        return {"changed": False, "before": facts, "after": facts}

    if ctx.check_mode:
        after = {"contents": policy}
        if facts == None:
            return {"changed": True, "before": {}, "after": after}
        return {"changed": True, "before": facts, "after": after}

    if facts == None:
        # CREATE
        payload = {"contents": policy}
        res = rundeck_request("POST", ctx.json_dumps(payload))
        if res.status == 201:
            after = get_acl()
            return {"changed": True, "before": {}, "after": after}
        elif res.status == 400:
            fail("Unable to validate ACL %s. Please ensure it's a valid ACL" % name)
        elif res.status == 409:
            fail("ACL %s already exists" % name)
        else:
            fail("Unhandled HTTP status %d when creating ACL" % res.status)
    else:
        # UPDATE
        payload = {"contents": policy}
        res = rundeck_request("PUT", ctx.json_dumps(payload))
        if res.status == 200:
            after = get_acl()
            return {"changed": True, "before": facts, "after": after}
        elif res.status == 400:
            fail("Unable to validate ACL %s. Please ensure it's a valid ACL" % name)
        elif res.status == 404:
            fail("ACL %s doesn't exist. Cannot update." % name)
        else:
            fail("Unhandled HTTP status %d when updating ACL" % res.status)
