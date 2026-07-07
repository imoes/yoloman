def main(ctx, params):
    category = params["category"]
    command_list = params["command"]
    baseuri = params["baseuri"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    attribute_name = params["attribute_name"]
    attribute_value = params.get("attribute_value")
    timeout = str(params.get("timeout", 10))

    # Validate category and commands
    allowed_commands = ["SetTimeZone", "SetDNSserver", "SetDomainName", "SetNTPServers", "SetWINSReg"]
    if category != "Manager":
        fail("Invalid category: '" + category + "'. Only 'Manager' is supported.")
    
    offending = [cmd for cmd in command_list if cmd not in allowed_commands]
    if offending:
        fail("Invalid Command(s): '" + str(offending) + "'. Allowed Commands = " + str(allowed_commands))

    # Build auth header (only one of username/password or auth_token allowed)
    auth_header = ""
    if auth_token != None:
        auth_header = "X-Auth-Token: " + auth_token
    elif username != None and password != None:
        # Base64 encoding without import: use ctx.run with base64 command
        credentials = username + ":" + password
        # Run base64 encoding via shell command
        b64_res = ctx.run(["printf", "%s", credentials], mutates=False)
        if b64_res.rc != 0:
            fail("Failed to prepare credentials")
        # We'll construct base64 manually for compatibility
        # Precomputed base64 alphabet mapping
        b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        
        def to_b64(s):
            result = []
            i = 0
            while i < len(s):
                c1 = ord(s[i]) if i < len(s) else 0
                c2 = ord(s[i+1]) if i+1 < len(s) else 0
                c3 = ord(s[i+2]) if i+2 < len(s) else 0
                
                result.append(b64_chars[(c1 >> 2) & 0x3F])
                result.append(b64_chars[((c1 & 3) << 4) | ((c2 >> 4) & 0x0F)])
                
                if i+1 < len(s):
                    result.append(b64_chars[((c2 & 0x0F) << 2) | ((c3 >> 6) & 0x03)])
                else:
                    result.append("=")
                
                if i+2 < len(s):
                    result.append(b64_chars[c3 & 0x3F])
                else:
                    result.append("=")
                
                i += 3
            return "".join(result)
        
        encoded = to_b64(credentials)
        auth_header = "Authorization: Basic " + encoded
    else:
        fail("Must provide either 'username' and 'password' or 'auth_token'.")

    # Build base URI and target URI
    root_uri = "https://" + baseuri + "/redfish/v1/Managers/1/Oem/Hp/Network"

    # Determine which command to execute (single command supported only for simplicity)
    if len(command_list) != 1:
        fail("Only single command execution is supported.")
    
    command = command_list[0]
    method = "POST"
    headers = [
        "Content-Type: application/json",
        auth_header,
        "Accept: application/json"
    ]
    
    # Prepare payload based on command
    payload = ""
    if command == "SetTimeZone":
        payload = '{"TimeZone":' + str(attribute_value) + '}'
    elif command == "SetDNSserver":
        payload = '{"DNSserver":' + str(attribute_value) + '}'
    elif command == "SetDomainName":
        payload = '{"DomainName":' + str(attribute_value) + '}'
    elif command == "SetNTPServers":
        payload = '{"StaticNTPServers":' + str(attribute_value) + '}'
    elif command == "SetWINSReg":
        payload = '{"WINSRegistration":' + str(attribute_value) + '}'
    else:
        fail("Unsupported command: " + command)

    # Execute request
    res = ctx.run([
        "curl",
        "-s",
        "-k",
        "-X", method,
        "-H", headers[0],
        "-H", headers[1],
        "-H", headers[2],
        "-d", payload,
        root_uri
    ], mutates=True)

    if res.skipped:
        return {"changed": True, "msg": "would execute " + command + " on " + category}

    if res.rc != 0:
        fail("Command '" + command + "' failed with rc=" + str(res.rc) + ": " + res.stderr)

    # Parse response for success indication (simplified check)
    # In practice, response would need careful parsing, but original module returns changed=True on success
    return {"changed": True, "msg": "Action was successful"}
