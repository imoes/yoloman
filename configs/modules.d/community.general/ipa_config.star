def main(ctx, params):
    # Extract common IPA connection parameters
    host = params.get("ipa_host", "ipa.example.com")
    port = params.get("ipa_port", 443)
    protocol = params.get("ipa_prot", "https")
    user = params.get("ipa_user", "admin")
    password = params.get("ipa_pass")
    validate_certs = params.get("validate_certs", True)

    # Build the IPA config request URL
    base_url = protocol + "://" + host + ":" + str(port) + "/ipa/session/json"
    
    # Step 1: Login to IPA using curl
    # Prepare the JSON payload string manually
    login_json = '{"method":"login","params":[[],{"user":"' + user + '","password":"' + password + '"}],"id":0}'
    login_res = ctx.run(
        [
            "curl", "-s", "-X", "POST", base_url,
            "-d", login_json, "--header", "Content-Type: application/json", "--header", "Accept: application/json"
        ],
        mutates=False
    )
    if login_res.rc != 0:
        fail("login failed: " + login_res.stderr)
    
    # Extract session cookie from Set-Cookie header
    cookie_line = ""
    for line in login_res.stderr.splitlines():
        if "Set-Cookie" in line:
            cookie_line = line.split(";")[0].strip()
            break
    if cookie_line == "":
        fail("login: no session cookie returned")
    
    headers = ["Content-Type: application/json", "Accept: application/json", cookie_line]

    # Step 2: Show current config
    show_json = '{"method":"config_show","params":[[],{}],"id":0}'
    show_res = ctx.run(
        [
            "curl", "-s", "-X", "POST", base_url,
            "-d", show_json, "--header", headers[0], "--header", headers[1], "--header", headers[2]
        ],
        mutates=False
    )
    if show_res.rc != 0:
        fail("config_show failed: " + show_res.stderr)

    # Parse JSON-like response manually (simple key extraction)
    show_data = show_res.stdout
    current_config = {}
    
    # Helper to extract string field
    def _extract_str(key):
        start = show_data.find('"' + key + '":')
        if start == -1:
            return None
        start += len('"' + key + '":')
        # Skip whitespace
        while start < len(show_data) and show_data[start] in ' \t':
            start += 1
        if start >= len(show_data):
            return None
        if show_data[start] != '"':
            return None
        start += 1
        end = start
        while end < len(show_data) and show_data[end] != '"':
            if show_data[end] == '\\' and end + 1 < len(show_data):
                end += 2
            else:
                end += 1
        if end >= len(show_data):
            return None
        return show_data[start:end]
    
    # Helper to extract list of strings (comma or JSON array style)
    def _extract_list(key):
        start = show_data.find('"' + key + '":')
        if start == -1:
            return []
        start += len('"' + key + '":')
        while start < len(show_data) and show_data[start] in ' \t':
            start += 1
        if start >= len(show_data):
            return []
        if show_data[start] != '[':
            # Fallback to string if not array
            val = _extract_str(key)
            if val == None:
                return []
            return val.split(',') if val != "" else []
        start += 1
        end = start
        depth = 1
        while end < len(show_data) and depth > 0:
            if show_data[end] == '"':
                end += 1
                while end < len(show_data) and show_data[end] != '"':
                    if show_data[end] == '\\' and end + 1 < len(show_data):
                        end += 2
                    else:
                        end += 1
                if end < len(show_data):
                    end += 1
            elif show_data[end] == '[':
                depth += 1
                end += 1
            elif show_data[end] == ']':
                depth -= 1
                end += 1
            else:
                end += 1
        if end >= len(show_data):
            return []
        inner = show_data[start:end-1]
        if inner.strip() == "":
            return []
        items = []
        for item in inner.split(','):
            item = item.strip().strip('"')
            if item != "":
                items.append(item)
        return items
    
    current_config["ipaconfigstring"] = _extract_list("ipaconfigstring")
    current_config["ipadefaultloginshell"] = _extract_str("ipadefaultloginshell")
    current_config["ipadefaultemaildomain"] = _extract_str("ipadefaultemaildomain")
    current_config["ipadefaultprimarygroup"] = _extract_str("ipadefaultprimarygroup")
    current_config["ipagroupsearchfields"] = _extract_list("ipagroupsearchfields")
    current_config["ipahomesrootdir"] = _extract_str("ipahomesrootdir")
    current_config["ipakrbauthzdata"] = _extract_list("ipakrbauthzdata")
    # For integer fields
    tmp_val = _extract_str("ipamaxusernamelength")
    current_config["ipamaxusernamelength"] = int(tmp_val) if tmp_val != None else None
    tmp_val = _extract_str("ipapwdexpadvnotify")
    current_config["ipapwdexpadvnotify"] = int(tmp_val) if tmp_val != None else None
    tmp_val = _extract_str("ipasearchrecordslimit")
    current_config["ipasearchrecordslimit"] = int(tmp_val) if tmp_val != None else None
    tmp_val = _extract_str("ipasearchtimelimit")
    current_config["ipasearchtimelimit"] = int(tmp_val) if tmp_val != None else None
    current_config["ipaselinuxusermaporder"] = _extract_list("ipaselinuxusermaporder")
    current_config["ipauserauthtype"] = _extract_list("ipauserauthtype")
    current_config["ipausersearchfields"] = _extract_list("ipausersearchfields")

    # Step 3: Build module_config (desired state)
    module_config = {}
    if params.get("ipaconfigstring") != None:
        module_config["ipaconfigstring"] = params["ipaconfigstring"]
    if params.get("ipadefaultloginshell") != None:
        module_config["ipadefaultloginshell"] = params["ipadefaultloginshell"]
    if params.get("ipadefaultemaildomain") != None:
        module_config["ipadefaultemaildomain"] = params["ipadefaultemaildomain"]
    if params.get("ipadefaultprimarygroup") != None:
        module_config["ipadefaultprimarygroup"] = params["ipadefaultprimarygroup"]
    if params.get("ipagroupsearchfields") != None:
        module_config["ipagroupsearchfields"] = ','.join(params["ipagroupsearchfields"])
    if params.get("ipahomesrootdir") != None:
        module_config["ipahomesrootdir"] = params["ipahomesrootdir"]
    if params.get("ipakrbauthzdata") != None:
        module_config["ipakrbauthzdata"] = params["ipakrbauthzdata"]
    if params.get("ipamaxusernamelength") != None:
        module_config["ipamaxusernamelength"] = str(params["ipamaxusernamelength"])
    if params.get("ipapwdexpadvnotify") != None:
        module_config["ipapwdexpadvnotify"] = str(params["ipapwdexpadvnotify"])
    if params.get("ipasearchrecordslimit") != None:
        module_config["ipasearchrecordslimit"] = str(params["ipasearchrecordslimit"])
    if params.get("ipasearchtimelimit") != None:
        module_config["ipasearchtimelimit"] = str(params["ipasearchtimelimit"])
    if params.get("ipaselinuxusermaporder") != None:
        module_config["ipaselinuxusermaporder"] = '$'.join(params["ipaselinuxusermaporder"])
    if params.get("ipauserauthtype") != None:
        module_config["ipauserauthtype"] = params["ipauserauthtype"]
    if params.get("ipausersearchfields") != None:
        module_config["ipausersearchfields"] = ','.join(params["ipausersearchfields"])

    # Step 4: Compute diff and determine changes
    changed = False
    update_config = {}
    for key in module_config:
        current_val = current_config.get(key)
        desired_val = module_config[key]
        if current_val != desired_val:
            changed = True
            update_config[key] = desired_val

    # In check_mode, just report what would change
    if ctx.check_mode:
        return {"changed": changed, "msg": "would update config", "data": {"config": current_config}}

    # Step 5: Apply changes if needed
    if changed:
        # Build JSON payload for config_mod
        mod_data = '{"method":"config_mod","params":[[],'
        # Simple dict-to-JSON conversion
        parts = []
        for k in update_config:
            v = update_config[k]
            if type(v) == "list":
                items = []
                for item in v:
                    items.append('"' + item + '"')
                parts.append('"' + k + '":[' + ','.join(items) + ']')
            elif type(v) == "int":
                parts.append('"' + k + '":' + str(v))
            else:
                parts.append('"' + k + '":"' + str(v) + '"')
        mod_data += '{' + ','.join(parts) + '}],"id":0}'
        
        mod_res = ctx.run(
            [
                "curl", "-s", "-X", "POST", base_url,
                "-d", mod_data, "--header", headers[0], "--header", headers[1], "--header", headers[2]
            ],
            mutates=True
        )
        if mod_res.rc != 0:
            fail("config_mod failed: " + mod_res.stderr)

    # Step 6: Return updated config
    return {"changed": changed, "msg": "config updated", "data": {"config": update_config}}
