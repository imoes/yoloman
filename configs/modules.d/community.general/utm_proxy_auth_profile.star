def main(ctx, params):
    # Required parameters
    name = params["name"]
    aaa = params["aaa"]
    basic_prompt = params["basic_prompt"]
    frontend_session_lifetime = params["frontend_session_lifetime"]
    frontend_session_timeout = params["frontend_session_timeout"]
    
    # Optional parameters with defaults
    state = params.get("state", "present")
    backend_mode = params.get("backend_mode", "None")
    backend_strip_basic_auth = params.get("backend_strip_basic_auth", True)
    backend_user_prefix = params.get("backend_user_prefix", "")
    backend_user_suffix = params.get("backend_user_suffix", "")
    comment = params.get("comment", "")
    frontend_cookie = params.get("frontend_cookie")
    frontend_cookie_secret = params.get("frontend_cookie_secret")
    frontend_form = params.get("frontend_form")
    frontend_form_template = params.get("frontend_form_template", "")
    frontend_login = params.get("frontend_login")
    frontend_logout = params.get("frontend_logout")
    frontend_mode = params.get("frontend_mode", "Basic")
    frontend_realm = params.get("frontend_realm")
    frontend_session_allow_persistency = params.get("frontend_session_allow_persistency", False)
    frontend_session_lifetime_limited = params.get("frontend_session_lifetime_limited", True)
    frontend_session_lifetime_scope = params.get("frontend_session_lifetime_scope", "hours")
    frontend_session_timeout_enabled = params.get("frontend_session_timeout_enabled", True)
    frontend_session_timeout_scope = params.get("frontend_session_timeout_scope", "minutes")
    logout_delegation_urls = params.get("logout_delegation_urls", [])
    logout_mode = params.get("logout_mode", "None")
    redirect_to_requested_url = params.get("redirect_to_requested_url", False)
    
    # UTM connection parameters
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)
    
    # Build endpoint URL
    endpoint = "/api/objects/reverse_proxy/auth_profile/"
    url = utm_protocol + "://" + utm_host + ":" + str(utm_port) + endpoint
    
    # Build headers
    headers = {"X-Auth-Token": utm_token}
    if params.get("headers"):
        for k, v in params.get("headers").items():
            headers[k] = v
    
    # Helper to build request body
    def build_body():
        body = {
            "name": name,
            "aaa": aaa,
            "basic_prompt": basic_prompt,
            "backend_mode": backend_mode,
            "backend_strip_basic_auth": backend_strip_basic_auth,
            "backend_user_prefix": backend_user_prefix,
            "backend_user_suffix": backend_user_suffix,
            "comment": comment,
            "frontend_session_lifetime": frontend_session_lifetime,
            "frontend_session_timeout": frontend_session_timeout
        }
        if frontend_cookie != None:
            body["frontend_cookie"] = frontend_cookie
        if frontend_cookie_secret != None:
            body["frontend_cookie_secret"] = frontend_cookie_secret
        if frontend_form != None:
            body["frontend_form"] = frontend_form
        if frontend_form_template != "":
            body["frontend_form_template"] = frontend_form_template
        if frontend_login != None:
            body["frontend_login"] = frontend_login
        if frontend_logout != None:
            body["frontend_logout"] = frontend_logout
        if frontend_mode != "Basic":
            body["frontend_mode"] = frontend_mode
        if frontend_realm != None:
            body["frontend_realm"] = frontend_realm
        if frontend_session_allow_persistency != False:
            body["frontend_session_allow_persistency"] = frontend_session_allow_persistency
        if frontend_session_lifetime_limited != True:
            body["frontend_session_lifetime_limited"] = frontend_session_lifetime_limited
        if frontend_session_lifetime_scope != "hours":
            body["frontend_session_lifetime_scope"] = frontend_session_lifetime_scope
        if frontend_session_timeout_enabled != True:
            body["frontend_session_timeout_enabled"] = frontend_session_timeout_enabled
        if frontend_session_timeout_scope != "minutes":
            body["frontend_session_timeout_scope"] = frontend_session_timeout_scope
        if logout_delegation_urls != []:
            body["logout_delegation_urls"] = logout_delegation_urls
        if logout_mode != "None":
            body["logout_mode"] = logout_mode
        if redirect_to_requested_url != False:
            body["redirect_to_requested_url"] = redirect_to_requested_url
        return body
    
    # Check current state - get existing object by name
    res = ctx.run(["curl", "-s", "-k", "-H", "Content-Type: application/json",
                   "-H", "X-Auth-Token: " + utm_token,
                   url], mutates=False)
    if res.rc != 0:
        fail("Failed to list objects: " + res.stderr)
    
    # Parse response to find existing object
    objects_str = res.stdout
    existing_ref = None
    lines = objects_str.split("\n")
    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        # Basic JSON parsing for object with matching name
        if stripped.startswith("{") and stripped.endswith("}"):
            # Simple check for name field - real implementation would parse JSON
            # Since we can't use json module, use string search
            if "\"name\"" in stripped and ("\"" + name + "\"") in stripped:
                # Extract _ref if present
                if "\"_ref\":" in stripped or "'_ref':" in stripped:
                    ref_start = stripped.find("\"_ref\":") + 8
                    if ref_start < 8:
                        ref_start = stripped.find("'") + 1
                        ref_end = stripped.find("'", ref_start)
                    else:
                        ref_end = stripped.find("\"", ref_start)
                    if ref_end > ref_start:
                        existing_ref = stripped[ref_start:ref_end]
                break
    
    # Handle state
    if state == "absent":
        if existing_ref == None:
            return {"changed": False, "msg": "Object %s does not exist" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete object " + name}
        res = ctx.run(["curl", "-s", "-k", "-X", "DELETE", "-H", "Content-Type: application/json",
                       "-H", "X-Auth-Token: " + utm_token,
                       url + existing_ref], mutates=True)
        if res.rc != 0:
            fail("Failed to delete object: " + res.stderr)
        return {"changed": True, "msg": "Deleted object " + name}
    
    # state == "present"
    body = build_body()
    body_json = str(body)  # Note: This is a simplified representation
    
    if existing_ref == None:
        # Create new object
        if ctx.check_mode:
            return {"changed": True, "msg": "would create object " + name}
        res = ctx.run(["curl", "-s", "-k", "-X", "POST", "-H", "Content-Type: application/json",
                       "-H", "X-Auth-Token: " + utm_token,
                       "-d", body_json, url], mutates=True)
        if res.rc != 0:
            fail("Failed to create object: " + res.stderr)
        return {"changed": True, "msg": "Created object " + name}
    else:
        # Update existing object
        if ctx.check_mode:
            return {"changed": True, "msg": "would update object " + name}
        res = ctx.run(["curl", "-s", "-k", "-X", "PUT", "-H", "Content-Type: application/json",
                       "-H", "X-Auth-Token: " + utm_token,
                       "-d", body_json, url + existing_ref], mutates=True)
        if res.rc != 0:
            fail("Failed to update object: " + res.stderr)
        return {"changed": True, "msg": "Updated object " + name}
