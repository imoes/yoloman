def main(ctx, params):
    # Extract required configuration
    host = params.get("ipa_host", "ipa.example.com")
    port = params.get("ipa_port", 443)
    protocol = params.get("ipa_prot", "https")
    user = params.get("ipa_user", "admin")
    password = params.get("ipa_pass")
    validate_certs = params.get("validate_certs", True)
    timeout = params.get("ipa_timeout", 10)

    # Build OTP config dict from params
    module_otpconfig = {}
    for key in [
        "ipatokentotpauthwindow", "ipatokentotpsyncwindow",
        "ipatokenhotpauthwindow", "ipatokenhotpsyncwindow"
    ]:
        if key in params:
            module_otpconfig[key] = str(params[key])

    # Determine IPA base URL
    base_url = protocol + "://" + host + ":" + str(port) + "/ipa"

    # Build curl args for authentication
    curl_base = [
        "curl", "-s", "-S",
        "-H", "Referer: " + base_url,
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "--cacert", "/etc/ipa/ca.crt" if validate_certs else "/dev/null",
        "--connect-timeout", str(timeout),
        "--max-time", str(timeout * 10)
    ]

    # Login with user/pass
    login_url = base_url + "/session/json"
    login_data = '{"method":"session_login","params":[[],{"password":"' + password + '","user":"' + user + '"}]}'

    login_res = ctx.run(curl_base + ["-X", "POST", "-d", login_data, login_url])
    if login_res.rc != 0:
        fail("login failed: " + login_res.stderr)

    # Show current OTP config
    show_data = '{"method":"otpconfig_show","params":[[],{}]}'
    show_res = ctx.run(curl_base + ["-X", "POST", "-d", show_data, login_url])
    if show_res.rc != 0:
        fail("otpconfig_show failed: " + show_res.stderr)

    # Parse response (simple JSON extraction using string search)
    raw = show_res.stdout
    if not raw.startswith('{"result":'):
        fail("unexpected otpconfig_show output")
    
    start = -1
    for i in range(len(raw)):
        if raw[i] == '{' and raw[i:i+9] == '{"result:"':
            start = i
            break
    if start == -1:
        fail("could not parse otpconfig_show output: missing result wrapper")
    
    end = -1
    brace_count = 0
    for i in range(start, len(raw)):
        if raw[i] == '{':
            brace_count = brace_count + 1
        elif raw[i] == '}':
            brace_count = brace_count - 1
            if brace_count == 0:
                end = i + 1
                break
    if end == -1:
        fail("could not parse otpconfig_show output: unmatched braces")
    
    result_str = raw[start:end]

    # Extract values manually (Starlark has no json module)
    def get_config_value(result_str, key):
        search = '"' + key + '":'
        i = result_str.find(search)
        if i == -1:
            return None
        val_start = i + len(search)
        val_part = result_str[val_start:]
        # Skip whitespace
        j = 0
        while j < len(val_part) and val_part[j] in " \t\n\r":
            j = j + 1
        val_part = val_part[j:]
        # Expect string
        if len(val_part) == 0 or val_part[0] != '"':
            return None
        val_part = val_part[1:]
        end_q = -1
        for k in range(len(val_part)):
            if val_part[k] == '"':
                end_q = k
                break
        if end_q == -1:
            return None
        return val_part[:end_q]

    ipa_otpconfig = {}
    for key in module_otpconfig.keys():
        val = get_config_value(result_str, key)
        if val != None:
            ipa_otpconfig[key] = val

    # Compute diff
    diff_keys = []
    for key in module_otpconfig.keys():
        desired = module_otpconfig[key]
        current = ipa_otpconfig.get(key)
        if current != desired:
            diff_keys.append(key)

    changed = len(diff_keys) > 0

    if changed and ctx.check_mode:
        return {"changed": True, "msg": "would update OTP configuration", "data": {"otpconfig": dict(ipa_otpconfig)}}

    if changed:
        # Build mod payload
        mod_item = {}
        for key in diff_keys:
            mod_item[key] = module_otpconfig[key]
        # Convert to JSON-like string manually
        items = []
        for key in mod_item.keys():
            items.append('"' + key + '": "' + mod_item[key] + '"')
        mod_json = "{" + ", ".join(items) + "}"
        mod_data = '{"method":"otpconfig_mod","params":[null,{"item": ' + mod_json + '}]}'
        mod_res = ctx.run(curl_base + ["-X", "POST", "-d", mod_data, login_url])
        if mod_res.rc != 0:
            fail("otpconfig_mod failed: " + mod_res.stderr)

    # Re-fetch OTP config for return
    show_res2 = ctx.run(curl_base + ["-X", "POST", "-d", show_data, login_url])
    if show_res2.rc != 0:
        fail("final otpconfig_show failed: " + show_res2.stderr)

    raw2 = show_res2.stdout
    if not raw2.startswith('{"result":'):
        fail("could not parse final otpconfig_show output")
    
    start2 = -1
    for i in range(len(raw2)):
        if raw2[i] == '{' and raw2[i:i+9] == '{"result:"':
            start2 = i
            break
    if start2 == -1:
        fail("could not parse final otpconfig_show output: missing result wrapper")
    
    end2 = -1
    brace_count = 0
    for i in range(start2, len(raw2)):
        if raw2[i] == '{':
            brace_count = brace_count + 1
        elif raw2[i] == '}':
            brace_count = brace_count - 1
            if brace_count == 0:
                end2 = i + 1
                break
    if end2 == -1:
        fail("could not parse final otpconfig_show output: unmatched braces")
    
    result_str2 = raw2[start2:end2]

    final_otpconfig = {}
    for key in module_otpconfig.keys():
        val = get_config_value(result_str2, key)
        if val != None:
            final_otpconfig[key] = val

    return {
        "changed": changed,
        "msg": "OTP configuration updated" if changed else "OTP configuration already in desired state",
        "data": {"otpconfig": final_otpconfig}
    }
