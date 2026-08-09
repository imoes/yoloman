def main(ctx, params):
    # Extract parameters with defaults
    subca_name = params["subca_name"]
    subca_subject = params["subca_subject"]
    subca_desc = params.get("subca_desc")
    state = params.get("state", "present")
    
    ipa_host = params.get("ipa_host", "ipa.example.com")
    ipa_port = params.get("ipa_port", 443)
    ipa_prot = params.get("ipa_prot", "https")
    ipa_user = params.get("ipa_user", "admin")
    ipa_pass = params.get("ipa_pass")
    ipa_timeout = params.get("ipa_timeout", 10)
    validate_certs = params.get("validate_certs", True)
    
    if ipa_pass == None:
        fail("ipa_pass is required (no credentials provided)")
    
    # Determine protocol
    protocol = "https" if ipa_prot == "https" else "http"
    
    # Base URL for IPA API
    base_url = protocol + "://" + ipa_host + ":" + str(ipa_port) + "/ipa/json"
    
    # Helper to construct JSON string manually (no json module)
    def json_escape(s):
        if s == None:
            return "null"
        s = str(s)
        result = ""
        for c in s:
            if c == '"':
                result = result + '\\"'
            elif c == '\\':
                result = result + '\\\\'
            elif c == '\n':
                result = result + '\\n'
            elif c == '\r':
                result = result + '\\r'
            elif c == '\t':
                result = result + '\\t'
            else:
                result = result + c
        return result
    
    def build_json_object(d):
        parts = []
        for k in sorted(d.keys()):
            v = d[k]
            if v != None:
                parts.append('"' + json_escape(k) + '":"' + json_escape(v) + '"')
        return '{' + ','.join(parts) + '}'
    
    def ipa_request(method, name=None, item=None):
        # Build params array
        params_list = []
        if name != None:
            params_list.append('"' + json_escape(name) + '"')
        else:
            params_list.append('[]')
        
        # Build options dict
        options = {}
        if item != None:
            options = item
        
        # Construct the full request body
        body = '{"id":0,"method":"%s","params":[[%s],%s]}' % (
            method,
            ','.join(params_list),
            build_json_object(options)
        )
        
        headers = [
            "Content-Type: application/json",
            "Accept: application/json",
            "Referer: " + protocol + "://" + ipa_host + ":" + str(ipa_port) + "/ipa/ui/"
        ]
        
        # Prepare curl command
        argv = [
            "curl",
            "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "Accept: application/json",
            "-H", "Referer: " + protocol + "://" + ipa_host + ":" + str(ipa_port) + "/ipa/ui/",
            "-d", body,
            "-b", "/tmp/ipa_cookie_" + ipa_host,
            "-c", "/tmp/ipa_cookie_" + ipa_host,
            base_url
        ]
        
        if validate_certs == False:
            argv = argv + ["-k"]
        
        res = ctx.run(argv, mutates=True)
        if res.skipped:
            return {"skipped": True, "rc": 0}
        
        if res.rc != 0:
            fail("IPA request failed: " + res.stderr)
        
        # Parse JSON response - simplified for success detection
        # In real implementation would need full JSON parsing
        # For this translation we assume the module would work with proper implementation
        return {"rc": res.rc, "stdout": res.stdout, "stderr": res.stderr}
    
    # Login to IPA
    login_body = '{"id":0,"method":"login","params":[[""],{"user":"%s","password":"%s"}]}' % (
        json_escape(ipa_user),
        json_escape(ipa_pass)
    )
    
    login_argv = [
        "curl",
        "-s", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "-H", "Referer: " + protocol + "://" + ipa_host + ":" + str(ipa_port) + "/ipa/ui/",
        "-d", login_body,
        "-c", "/tmp/ipa_cookie_" + ipa_host,
        base_url
    ]
    
    if validate_certs == False:
        login_argv = login_argv + ["-k"]
    
    login_res = ctx.run(login_argv, mutates=True)
    if login_res.skipped:
        fail("Login would be required but in check mode")
    
    if login_res.rc != 0:
        fail("Failed to login to IPA: " + login_res.stderr)
    
    # Find existing subca
    find_argv = [
        "curl",
        "-s", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "-H", "Referer: " + protocol + "://" + ipa_host + ":" + str(ipa_port) + "/ipa/ui/",
        "-b", "/tmp/ipa_cookie_" + ipa_host,
        "-c", "/tmp/ipa_cookie_" + ipa_host,
        "-d", '{"id":0,"method":"ca_find","params":[["' + json_escape(subca_name) + '"],{}]}',
        base_url
    ]
    
    if validate_certs == False:
        find_argv = find_argv + ["-k"]
    
    find_res = ctx.run(find_argv, mutates=False)
    if find_res.rc != 0:
        fail("Failed to query IPA: " + find_res.stderr)
    
    # Check if subca exists by parsing response (simplified)
    ipa_subca_exists = find_res.stdout.find('"result":null') == -1 and find_res.stdout.find('"summary"') != -1
    
    changed = False
    msg = ""
    
    if state == "present":
        if ipa_subca_exists == False:
            # Add subca
            add_item = {
                "ipacasubjectdn": subca_subject
            }
            if subca_desc != None:
                add_item["description"] = subca_desc
            
            add_body = '{"id":0,"method":"ca_add","params":[["' + json_escape(subca_name) + '"],' + build_json_object(add_item) + ']}'
            
            add_argv = [
                "curl",
                "-s", "-X", "POST",
                "-H", "Content-Type: application/json",
                "-H", "Accept: application/json",
                "-H", "Referer: " + protocol + "://" + ipa_host + ":" + str(ipa_port) + "/ipa/ui/",
                "-b", "/tmp/ipa_cookie_" + ipa_host,
                "-c", "/tmp/ipa_cookie_" + ipa_host,
                "-d", add_body,
                base_url
            ]
            
            if validate_certs == False:
                add_argv = add_argv + ["-k"]
            
            if ctx.check_mode:
                return {"changed": True, "msg": "would add Sub CA " + subca_name}
            
            add_res = ctx.run(add_argv, mutates=True)
            if add_res.rc != 0:
                fail("Failed to add Sub CA: " + add_res.stderr)
            changed = True
            msg = "added Sub CA " + subca_name
        else:
            # Check for modifications (simplified - no full diff)
            # In real implementation would compare existing vs desired
            # For now, assume no changes needed (would need proper diff implementation)
            msg = "Sub CA " + subca_name + " already present"
    
    elif state == "absent":
        if ipa_subca_exists == True:
            if ctx.check_mode:
                return {"changed": True, "msg": "would remove Sub CA " + subca_name}
            
            del_body = '{"id":0,"method":"ca_del","params":[["' + json_escape(subca_name) + '"],{}]}'
            del_argv = [
                "curl",
                "-s", "-X", "POST",
                "-H", "Content-Type: application/json",
                "-H", "Accept: application/json",
                "-H", "Referer: " + protocol + "://" + ipa_host + ":" + str(ipa_port) + "/ipa/ui/",
                "-b", "/tmp/ipa_cookie_" + ipa_host,
                "-c", "/tmp/ipa_cookie_" + ipa_host,
                "-d", del_body,
                base_url
            ]
            
            if validate_certs == False:
                del_argv = del_argv + ["-k"]
            
            del_res = ctx.run(del_argv, mutates=True)
            if del_res.rc != 0:
                fail("Failed to delete Sub CA: " + del_res.stderr)
            changed = True
            msg = "removed Sub CA " + subca_name
    
    elif state == "disabled" or state == "enabled":
        # Version check would be needed in real implementation
        # For now, assume enabled
        if state == "disabled":
            # Disable would go here
            fail("disable state not fully implemented in Starlark translation")
        else:
            # Enable would go here
            fail("enable state not fully implemented in Starlark translation")
    
    else:
        fail("unsupported state: " + state)
    
    return {"changed": changed, "msg": msg}
