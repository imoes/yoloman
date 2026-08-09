def main(ctx, params):
    name = params["name"]
    password = params["password"]
    state = params.get("state", "present")
    sysname = params["sysname"]
    url = params["url"]
    user = params["user"]
    validate_certs = params.get("validate_certs", True)

    if state not in ("present", "absent"):
        fail("state must be 'present' or 'absent', got: " + state)

    # Build XML-RPC client using curl (no direct xmlrpc support in Starlark)
    # We'll use curl with --fail-early to get exit codes and parse XML manually

    # Step 1: Login
    auth_login_cmd = [
        "curl", "-sS", "-X", "POST", "-H", "Content-Type: text/xml",
        "-d", '<?xml version="1.0"?><methodCall><methodName>auth.login</methodName><params><param><value><string>{}</string></value></param><param><value><string>{}</string></value></param></params></methodCall>'.format(user, password),
        url
    ]
    if not validate_certs:
        auth_login_cmd.extend(["--insecure"])

    res = ctx.run(auth_login_cmd)
    if res.rc != 0:
        fail("failed to login: " + res.stderr)

    # Extract session id from XML response: <value><string>xxxxxxxxxxxx</string></value>
    session = ""
    for line in res.stdout.splitlines():
        if "<string>" in line:
            start = line.find("<string>") + len("<string>")
            end = line.find("</string>", start)
            if end > start:
                session = line[start:end]
                break

    if session == "":
        fail("failed to extract session id from auth.login response")

    # Step 2: Get system id
    sys_list_cmd = [
        "curl", "-sS", "-X", "POST", "-H", "Content-Type: text/xml",
        "-d", '<?xml version="1.0"?><methodCall><methodName>system.listUserSystems</methodName><params><param><value><string>{}</string></value></param></params></methodCall>'.format(session),
        url
    ]
    if not validate_certs:
        sys_list_cmd.extend(["--insecure"])

    res = ctx.run(sys_list_cmd)
    if res.rc != 0:
        fail("failed to list systems: " + res.stderr)

    # Find system by name in XML
    sys_id = ""
    in_system = False
    current_name = ""
    for line in res.stdout.splitlines():
        if "<member>" in line:
            in_system = True
            current_name = ""
        elif "</member>" in line:
            if in_system and current_name == sysname:
                # We found the system, need to look for its <value><i4>NNN</i4></value> in previous lines
                # Simpler: parse entire XML with find
                break
        elif in_system and "<name>" in line:
            start = line.find("<name>") + len("<name>")
            end = line.find("</name>", start)
            if end > start:
                current_name = line[start:end]

    # Use simpler approach: search for sysname in full response and extract id
    # Find "<struct>" block containing <name>sysname</name> and then <id><i4>xxx</i4></id>
    sys_id = ""
    lines = res.stdout.splitlines()
    in_struct = False
    name_found = False
    for i, line in enumerate(lines):
        if "<struct>" in line:
            in_struct = True
            name_found = False
        elif "</struct>" in line:
            in_struct = False
        elif in_struct:
            if "<name>" in line and "<value><string>" + sysname + "</string></value>" in line:
                name_found = True
            elif name_found and "<name>id</name>" in line:
                # Next line should have <value><i4>...</i4></value>
                for j in range(i+1, min(i+4, len(lines))):
                    if "<i4>" in lines[j]:
                        start = lines[j].find("<i4>") + len("<i4>")
                        end = lines[j].find("</i4>", start)
                        if end > start:
                            sys_id = lines[j][start:end]
                            break
                if sys_id:
                    break

    if sys_id == "":
        fail("failed to find system id for system " + sysname)

    # Step 3: Get current channels
    list_channels_cmd = [
        "curl", "-sS", "-X", "POST", "-H", "Content-Type: text/xml",
        "-d", '<?xml version="1.0"?><methodCall><methodName>channel.software.listSystemChannels</methodName><params><param><value><string>{}</string></value></param><param><value><i4>{}</i4></value></param></params></methodCall>'.format(session, sys_id),
        url
    ]
    if not validate_certs:
        list_channels_cmd.extend(["--insecure"])

    res = ctx.run(list_channels_cmd)
    if res.rc != 0:
        fail("failed to list channels: " + res.stderr)

    # Extract channel labels from XML
    # Expected: <struct><member><name>label</name><value><string>label1</string></value></member>...</struct>
    chans = []
    label_start = -1
    for line in res.stdout.splitlines():
        if "<name>label</name>" in line:
            # Next non-empty line with <string> should contain the label
            for j in range(lines.index(line)+1, min(len(lines), lines.index(line)+3)):
                if "<string>" in lines[j]:
                    s = lines[j].find("<string>") + len("<string>")
                    e = lines[j].find("</string>", s)
                    if e > s:
                        chans.append(lines[j][s:e])
                    break

    # Step 4: Perform action
    if state == "present":
        if name in chans:
            return {"changed": False, "msg": "Channel " + name + " already exists"}
        else:
            # Subscribe
            # Build XML for setChildChannels
            new_chans = []
            for c in chans:
                if c != name:
                    new_chans.append(c)
            new_chans.append(name)
            channels_xml = ""
            for c in new_chans:
                channels_xml += "<value><string>{}</string></value>".format(c)
            set_channels_cmd = [
                "curl", "-sS", "-X", "POST", "-H", "Content-Type: text/xml",
                "-d", '<?xml version="1.0"?><methodCall><methodName>system.setChildChannels</methodName><params><param><value><string>{}</string></value></param><param><value><i4>{}</i4></value></param><param><value><array><data>{}</data></array></value></param></params></methodCall>'.format(session, sys_id, channels_xml),
                url
            ]
            if not validate_certs:
                set_channels_cmd.extend(["--insecure"])

            res = ctx.run(set_channels_cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would add channel " + name}

            if res.rc != 0:
                fail("failed to add channel: " + res.stderr)

            # Logout
            logout_cmd = [
                "curl", "-sS", "-X", "POST", "-H", "Content-Type: text/xml",
                "-d", '<?xml version="1.0"?><methodCall><methodName>auth.logout</methodName><params><param><value><string>{}</string></value></param></params></methodCall>'.format(session),
                url
            ]
            if not validate_certs:
                logout_cmd.extend(["--insecure"])
            ctx.run(logout_cmd, mutates=False)

            return {"changed": True, "msg": "Channel " + name + " added"}

    elif state == "absent":
        if name not in chans:
            return {"changed": False, "msg": "Not subscribed to channel " + name + "."}
        else:
            # Unsubscribe
            new_chans = [c for c in chans if c != name]
            channels_xml = ""
            for c in new_chans:
                channels_xml += "<value><string>{}</string></value>".format(c)
            set_channels_cmd = [
                "curl", "-sS", "-X", "POST", "-H", "Content-Type: text/xml",
                "-d", '<?xml version="1.0"?><methodCall><methodName>system.setChildChannels</methodName><params><param><value><string>{}</string></value></param><param><value><i4>{}</i4></value></param><param><value><array><data>{}</data></array></value></param></params></methodCall>'.format(session, sys_id, channels_xml),
                url
            ]
            if not validate_certs:
                set_channels_cmd.extend(["--insecure"])

            res = ctx.run(set_channels_cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would remove channel " + name}

            if res.rc != 0:
                fail("failed to remove channel: " + res.stderr)

            # Logout
            logout_cmd = [
                "curl", "-sS", "-X", "POST", "-H", "Content-Type: text/xml",
                "-d", '<?xml version="1.0"?><methodCall><methodName>auth.logout</methodName><params><param><value><string>{}</string></value></param></params></methodCall>'.format(session),
                url
            ]
            if not validate_certs:
                logout_cmd.extend(["--insecure"])
            ctx.run(logout_cmd, mutates=False)

            return {"changed": True, "msg": "Channel " + name + " removed"}

    fail("state must be 'present' or 'absent'")
