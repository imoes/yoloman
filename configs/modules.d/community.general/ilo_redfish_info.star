def main(ctx, params):
    baseuri = params["baseuri"]
    category_list = params["category"]
    command_list = params["command"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    timeout = params.get("timeout", 10)

    # Validate credentials
    if auth_token == None and username == None:
        fail("missing required argument: username or auth_token")
    if auth_token != None and username != None:
        fail("cannot specify both username and auth_token")
    if username != None and password == None:
        fail("missing required argument: password when using username")

    # Build credentials dict
    creds = {}
    if username != None:
        creds["user"] = username
        creds["pswd"] = password
    if auth_token != None:
        creds["token"] = auth_token

    root_uri = "https://" + baseuri

    # Category and command validation constants
    CATEGORY_COMMANDS_ALL = {
        "Sessions": ["GetiLOSessions"]
    }

    CATEGORY_COMMANDS_DEFAULT = {
        "Sessions": "GetiLOSessions"
    }

    # Build Category list
    if "all" in category_list:
        category_list = list(CATEGORY_COMMANDS_ALL.keys())

    # Build Command list per category
    commands_by_category = {}
    for category in category_list:
        if category not in CATEGORY_COMMANDS_ALL:
            fail("Invalid Category: " + category)
        cmds = params.get("command", [])
        if not cmds or "all" in cmds:
            commands_by_category[category] = CATEGORY_COMMANDS_ALL[category]
        else:
            for cmd in cmds:
                if cmd not in CATEGORY_COMMANDS_ALL[category]:
                    fail("Invalid Command: " + cmd)
            commands_by_category[category] = cmds

    # Prepare result structure
    result = {}

    # Only Sessions category supported for now
    for category in category_list:
        if category != "Sessions":
            fail("Unsupported category: " + category)
        for command in commands_by_category.get(category, [CATEGORY_COMMANDS_DEFAULT[category]]):
            if command == "GetiLOSessions":
                # Call ilo_redfish_utils logic via shell: use curl to hit Redfish endpoint
                # Construct auth header
                if auth_token != None:
                    auth_header = '"Authorization: Bearer ' + auth_token + '"'
                else:
                    # Manual base64 encoding for Basic auth
                    auth_string = username + ":" + password
                    # Simple base64 table for ASCII (no full implementation needed for common cases)
                    base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
                    encoded = ""
                    i = 0
                    while i < len(auth_string):
                        c1 = ord(auth_string[i])
                        encoded += base64_chars[(c1 >> 2) & 0x3F]
                        if i + 1 < len(auth_string):
                            c2 = ord(auth_string[i + 1])
                            encoded += base64_chars[((c1 & 0x03) << 4) | ((c2 >> 4) & 0x0F)]
                            if i + 2 < len(auth_string):
                                c3 = ord(auth_string[i + 2])
                                encoded += base64_chars[((c2 & 0x0F) << 2) | ((c3 >> 6) & 0x03)]
                                encoded += base64_chars[c3 & 0x3F]
                            else:
                                encoded += base64_chars[(c2 & 0x0F) << 2]
                                encoded += "=="
                        else:
                            encoded += base64_chars[(c1 & 0x03) << 4]
                            encoded += "=="
                        i += 3
                    auth_header = '"Authorization: Basic ' + encoded + '"'

                # Build request
                url = root_uri + "/redfish/v1/SessionService/Sessions"
                # Use curl with timeout and suppress progress output
                res = ctx.run([
                    "curl", "-s", "-k", "-X", "GET", "-H", "Accept: application/json",
                    "-H", auth_header,
                    "--connect-timeout", str(timeout),
                    url
                ], mutates=False)

                if res.rc != 0:
                    fail("failed to get iLO sessions: " + res.stderr)

                # Parse JSON manually: find Members array and extract session objects
                stdout = res.stdout
                # Locate Members array
                members_start = stdout.find('"Members"')
                if members_start == -1:
                    fail("invalid response from iLO: no Members found")
                # Move to '[' after 'Members":'
                bracket_start = stdout.find('[', members_start)
                if bracket_start == -1:
                    fail("invalid response from iLO: no Members array")
                bracket_end = stdout.rfind(']')
                if bracket_end == -1 or bracket_end < bracket_start:
                    fail("invalid response from iLO: malformed Members array")
                members_str = stdout[bracket_start:bracket_end + 1]

                # Extract top-level objects using brace matching
                def extract_objects(s):
                    objs = []
                    depth = 0
                    start = -1
                    for i in range(len(s)):
                        c = s[i]
                        if c == '{':
                            if depth == 0:
                                start = i
                            depth += 1
                        elif c == '}':
                            depth -= 1
                            if depth == 0 and start != -1:
                                objs.append(s[start:i+1])
                                start = -1
                    return objs

                obj_strs = extract_objects(members_str)
                session_list = []
                for obj in obj_strs:
                    sess = {}
                    # Extract Id
                    id_key = '"Id":'
                    id_idx = obj.find(id_key)
                    if id_idx != -1:
                        val_start = id_idx + len(id_key)
                        val_end = obj.find(',', val_start)
                        if val_end == -1:
                            val_end = obj.find('}', val_start)
                        sess["Id"] = obj[val_start:val_end].strip().strip('"')
                    # Extract Name
                    name_key = '"Name":'
                    name_idx = obj.find(name_key)
                    if name_idx != -1:
                        val_start = name_idx + len(name_key)
                        val_end = obj.find(',', val_start)
                        if val_end == -1:
                            val_end = obj.find('}', val_start)
                        sess["Name"] = obj[val_start:val_end].strip().strip('"')
                    # Extract UserName
                    user_key = '"UserName":'
                    user_idx = obj.find(user_key)
                    if user_idx != -1:
                        val_start = user_idx + len(user_key)
                        val_end = obj.find(',', val_start)
                        if val_end == -1:
                            val_end = obj.find('}', val_start)
                        sess["UserName"] = obj[val_start:val_end].strip().strip('"')
                    # Extract Description
                    desc_key = '"Description":'
                    desc_idx = obj.find(desc_key)
                    if desc_idx != -1:
                        val_start = desc_idx + len(desc_key)
                        val_end = obj.find(',', val_start)
                        if val_end == -1:
                            val_end = obj.find('}', val_start)
                        sess["Description"] = obj[val_start:val_end].strip().strip('"')
                    session_list.append(sess)
                result[command] = {"ret": True, "msg": session_list}
            else:
                fail("Unsupported command: " + command)
    return {"changed": False, "msg": "successfully gathered iLO information", "data": {"ilo_redfish_info": result}}
